import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// Keeps clipboard fetching independent of the search overlay's lifetime.
///
/// iOS has no API for the "Paste from Other Apps" setting, and reading text
/// another app copied can raise an Allow Paste prompt. So the cache learns
/// what it can from how reads behave and remembers it across launches:
/// - `allowed`: a quick read of new text we didn't copy ourselves. Safe to read
///   in the background, so the clipboard chip is ready the instant search opens.
///   Rereading text that was already read, or copied by us, proves nothing: iOS
///   doesn't ask again for text it has already let us read.
/// - `needsPermission`: a read was refused, or took long enough that a prompt
///   was most likely shown. Reads wait until search opens, and the search
///   panel keeps offering a way to Settings until a quick read proves it's on.
/// - `unknown`: nothing learned yet. Reads wait until search opens.
///
/// Whatever a read finds is also remembered in `ClipboardHistory`. Pictures
/// are only read once pasting is known to be allowed, since reading one can
/// raise the prompt too and nothing here would learn from it.
@MainActor
@Observable
final class ClipboardCache {
    static let shared = ClipboardCache()

    enum Access: String {
        case unknown, allowed, needsPermission
    }

    private(set) var text = ""
    private(set) var access = Access(
        rawValue: UserDefaults.standard.string(forKey: ClipboardCache.accessKey) ?? ""
    ) ?? .unknown
    /// The type identifiers on the pasteboard at the last read, one list per
    /// item. Shown in Settings > Debug, to see what a source app marks its
    /// copies with.
    private(set) var lastTypes: [[String]] = []
    private(set) var lastWasConcealed = false
    /// Incognito is on screen (a private tab, or the search field in private
    /// mode). The pasteboard doesn't say where a copy came from, so nothing
    /// new read meanwhile goes into the history.
    var isPrivate = false
    @ObservationIgnored private var cachedChangeCount = -1
    /// The clipboard as `ClipboardHistory` last wrote it. Already in the
    /// history, so reading it back must not record it again.
    @ObservationIgnored private var historyWriteCount = -1
    /// Clipboard contents a read was refused for, so search doesn't re-ask
    /// about the same contents every time it opens.
    @ObservationIgnored private var deniedChangeCount = -1
    /// The clipboard as we last wrote it, so our own copies can't be mistaken
    /// for proof that pasting from other apps is allowed. Kept across launches,
    /// since the clipboard is too.
    @ObservationIgnored private var ownChangeCount =
        UserDefaults.standard.object(forKey: ClipboardCache.ownCountKey) as? Int ?? -1
    /// What we last copied, compared by content too because the change count
    /// can move more than once for a single write.
    @ObservationIgnored private var ownCopiedText =
        UserDefaults.standard.string(forKey: ClipboardCache.ownTextKey)
    /// The clipboard as we last read it, also kept across launches.
    @ObservationIgnored private var lastReadChangeCount =
        UserDefaults.standard.object(forKey: ClipboardCache.lastReadCountKey) as? Int ?? -1
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    // The number restarts from `unknown`: earlier builds could wrongly save `allowed`.
    private static let accessKey = "clipboardAccess3"
    private static let ownCountKey = "clipboardOwnChangeCount"
    private static let ownTextKey = "clipboardOwnCopiedText"
    private static let lastReadCountKey = "clipboardLastReadChangeCount"
    /// A read slower than this was probably waiting on the Allow Paste prompt.
    private static let promptThreshold = 0.3

    private init() {}

    /// Forgets what was on the clipboard, for when it has just been emptied.
    func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        text = ""
        cachedChangeCount = -1
        ownCopiedText = nil
        UserDefaults.standard.removeObject(forKey: Self.ownTextKey)
    }

    /// Copies a link and remembers that the clipboard change was ours. A link
    /// copied in the app goes into the history right away, whether or not
    /// background reads are allowed.
    func copy(_ url: URL) {
        UIPasteboard.general.url = url
        noteOwnWrite(text: url.absoluteString)
        if AppSettings.shared.savesClipboardHistory {
            ClipboardHistory.shared.record(text: url.absoluteString, addsNew: !isPrivate)
        }
    }

    /// `ClipboardHistory` just put one of its own items on the clipboard.
    func noteHistoryWrite(text: String?) {
        noteOwnWrite(text: text)
        historyWriteCount = UIPasteboard.general.changeCount
    }

    private func noteOwnWrite(text: String?) {
        ownCopiedText = text
        UserDefaults.standard.set(text, forKey: Self.ownTextKey)
        // The count may only go up at the end of this run loop pass, so also
        // record it on the next one.
        recordOwnChange()
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { recordOwnChange() }
        }
    }

    private func recordOwnChange() {
        ownChangeCount = UIPasteboard.general.changeCount
        UserDefaults.standard.set(ownChangeCount, forKey: Self.ownCountKey)
    }

    /// Opens this app's page in Settings, where "Paste from Other Apps" lives.
    func openSettings() {
        deniedChangeCount = -1
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Background callers only read when that's known not to prompt; search
    /// opening passes `userInitiated` since a prompt is expected there.
    func refresh(userInitiated: Bool = false) {
        guard userInitiated || access == .allowed else { return }
        // Opening search or receiving another clipboard notification must not
        // cancel an in-flight Universal Clipboard fetch and start it over.
        guard refreshTask == nil else { return }
        let count = UIPasteboard.general.changeCount
        guard count != cachedChangeCount, count != deniedChangeCount else { return }
        text = ""
        refreshTask = Task {
            defer { if !Task.isCancelled { refreshTask = nil } }
            var deniedCount: Int?
            // A refusal or a slow read means the Allow Paste prompt came up in
            // this refresh. Remember that even when that read is thrown away
            // because the clipboard changed, since the retry that follows is
            // fast: iOS has already been answered.
            var wasPrompted = false
            // Retry transient empty reads without making the user reopen search.
            for attempt in 0..<4 {
                // The system refuses reads at once while the app isn't active
                // (launching), without asking. Wait for the app to be active.
                await waitUntilActive()
                // Still inactive: reads would be refused without a prompt, which
                // must not count as a denial. The next refresh will try again.
                guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
                let snapshot = await Self.read(readsImage: access == .allowed)
                // Cleared meanwhile (Incognito closed): what was read may be
                // private, so neither show it nor remember it.
                guard !Task.isCancelled else { return }
                if snapshot.hasText, snapshot.text == nil || snapshot.duration > Self.promptThreshold {
                    wasPrompted = true
                }
                if snapshot.before == snapshot.after {
                    // A picture that is still arriving (Universal Clipboard)
                    // keeps the read open, though its text needn't wait.
                    let isImagePending = snapshot.wantsImage && snapshot.image == nil
                    if let value = snapshot.text {
                        text = value
                        if !isImagePending {
                            cachedChangeCount = snapshot.after
                            deniedCount = nil
                            learnAccess(from: snapshot, afterPrompt: wasPrompted)
                            remember(snapshot)
                        }
                    } else if !snapshot.hasText {
                        text = ""
                        if !isImagePending {
                            cachedChangeCount = snapshot.after
                            deniedCount = nil
                            remember(snapshot)
                        }
                    } else {
                        deniedCount = snapshot.after
                    }
                    if cachedChangeCount == UIPasteboard.general.changeCount { return }
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
                }
            }
            // The clipboard has text but every read came back empty: refused.
            if let deniedCount {
                deniedChangeCount = deniedCount
                setAccess(.needsPermission)
            }
        }
    }

    /// Waits, for up to a few seconds, until the app is in the foreground.
    private func waitUntilActive() async {
        for _ in 0..<50 where !Task.isCancelled && UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func remember(_ snapshot: Snapshot) {
        lastTypes = snapshot.types
        lastWasConcealed = snapshot.isConcealed
        guard snapshot.after != historyWriteCount, Self.shouldRemember(
            isEnabled: AppSettings.shared.savesClipboardHistory,
            isConcealed: snapshot.isConcealed
        ) else { return }
        // While Incognito is showing, only items already in the history move
        // to the top (copying one back out of the panel); nothing new is kept.
        let addsNew = !isPrivate
        if let image = snapshot.image {
            ClipboardHistory.shared.record(image: image, addsNew: addsNew)
        } else if let text = snapshot.text {
            ClipboardHistory.shared.record(text: text, addsNew: addsNew)
        }
    }

    static func shouldRemember(isEnabled: Bool, isConcealed: Bool) -> Bool {
        isEnabled && !isConcealed
    }

    private func learnAccess(from snapshot: Snapshot, afterPrompt: Bool) {
        let isNew = snapshot.after != lastReadChangeCount
        lastReadChangeCount = snapshot.after
        UserDefaults.standard.set(snapshot.after, forKey: Self.lastReadCountKey)
        // A slow read means a prompt, even if we thought pasting was allowed:
        // reading in the background must stop, and the chip must show.
        if afterPrompt || snapshot.duration > Self.promptThreshold {
            setAccess(.needsPermission)
        } else if isNew, snapshot.after != ownChangeCount, snapshot.text != ownCopiedText {
            setAccess(.allowed)
        }
    }

    private func setAccess(_ newValue: Access) {
        guard access != newValue else { return }
        access = newValue
        UserDefaults.standard.set(newValue.rawValue, forKey: Self.accessKey)
    }

    private struct Snapshot: Sendable {
        let before: Int
        let after: Int
        let hasText: Bool
        let text: String?
        /// How long the text fetch blocked, in seconds.
        let duration: Double
        /// A picture is on the clipboard and no text is: it's what to keep.
        let wantsImage: Bool
        let image: ClipboardImage?
        /// A password manager marked this as a secret.
        let isConcealed: Bool
        let types: [[String]]
    }

    /// Password managers mark what they copy with this, asking clipboard
    /// tools not to keep it.
    nonisolated private static let concealedType = "org.nspasteboard.ConcealedType"

    /// UIPasteboard's synchronous fetch blocks, on Universal Clipboard or the
    /// Allow Paste prompt. Do it on a plain dispatch queue: blocking a Swift
    /// concurrency thread on it logs "unsafeForcedSync", and the main thread
    /// must stay free so UIKit can present the keyboard. Only immutable Swift
    /// values cross back to the main actor.
    nonisolated private static func read(readsImage: Bool) async -> Snapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: readClipboard(readsImage: readsImage))
            }
        }
    }

    nonisolated private static func readClipboard(readsImage: Bool) -> Snapshot {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        let isConcealed = pasteboard.contains(pasteboardTypes: [concealedType])
        let hasText = pasteboard.hasStrings || pasteboard.hasURLs
        let start = DispatchTime.now().uptimeNanoseconds
        let text = hasText ? (pasteboard.string ?? pasteboard.url?.absoluteString) : nil
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        // Copying a picture from a page also puts its address on the
        // clipboard; the picture is what was meant.
        let wantsImage = readsImage && !pasteboard.hasStrings && pasteboard.hasImages
        let image = wantsImage ? readImage(pasteboard) : nil
        return Snapshot(
            before: before, after: pasteboard.changeCount,
            hasText: hasText, text: text, duration: elapsed,
            wantsImage: wantsImage, image: image, isConcealed: isConcealed,
            types: pasteboard.types(forItemSet: IndexSet(0..<pasteboard.numberOfItems)) ?? []
        )
    }

    /// The picture's own bytes when the pasteboard has them, so photos
    /// aren't re-encoded into something much bigger.
    nonisolated private static func readImage(_ pasteboard: UIPasteboard) -> ClipboardImage? {
        for type in [UTType.png, .jpeg, .heic, .gif, .tiff] {
            if let data = pasteboard.data(forPasteboardType: type.identifier) {
                return ClipboardImage(data: data, type: type.identifier)
            }
        }
        guard let data = pasteboard.image?.pngData() else { return nil }
        return ClipboardImage(data: data, type: UTType.png.identifier)
    }
}
