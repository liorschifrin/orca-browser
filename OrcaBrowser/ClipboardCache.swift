import Foundation
import Observation
import UIKit

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
    @ObservationIgnored private var cachedChangeCount = -1
    /// Clipboard contents a read was refused for, so search doesn't re-ask
    /// about the same contents every time it opens.
    @ObservationIgnored private var deniedChangeCount = -1
    /// The clipboard as we last wrote it, so our own copies can't be mistaken
    /// for proof that pasting from other apps is allowed. Kept across launches,
    /// since the clipboard is too.
    @ObservationIgnored private var ownChangeCount =
        UserDefaults.standard.object(forKey: ClipboardCache.ownCountKey) as? Int ?? -1
    /// The clipboard as we last read it, also kept across launches.
    @ObservationIgnored private var lastReadChangeCount =
        UserDefaults.standard.object(forKey: ClipboardCache.lastReadCountKey) as? Int ?? -1
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    // The "2" restarts from `unknown`: earlier builds could wrongly save `allowed`.
    private static let accessKey = "clipboardAccess2"
    private static let ownCountKey = "clipboardOwnChangeCount"
    private static let lastReadCountKey = "clipboardLastReadChangeCount"
    /// A read slower than this was probably waiting on the Allow Paste prompt.
    private static let promptThreshold = 0.3

    private init() {}

    /// Copies a link and remembers that the clipboard change was ours.
    func copy(_ url: URL) {
        UIPasteboard.general.url = url
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
        NSLog("[Clipboard] refresh start userInitiated=%d access=%@ count=%d state=%ld", userInitiated, access.rawValue, count, UIApplication.shared.applicationState.rawValue)
        refreshTask = Task {
            defer { refreshTask = nil }
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
                let snapshot = await Self.read()
                if snapshot.hasText, snapshot.text == nil || snapshot.duration > Self.promptThreshold {
                    wasPrompted = true
                }
                NSLog("[Clipboard] attempt %d before=%d after=%d hasText=%d gotText=%d duration=%.3f state=%ld", attempt, snapshot.before, snapshot.after, snapshot.hasText, snapshot.text != nil, snapshot.duration, UIApplication.shared.applicationState.rawValue)
                if snapshot.before == snapshot.after {
                    if let value = snapshot.text {
                        text = value
                        cachedChangeCount = snapshot.after
                        deniedCount = nil
                        learnAccess(from: snapshot, afterPrompt: wasPrompted)
                    } else if !snapshot.hasText {
                        text = ""
                        cachedChangeCount = snapshot.after
                        deniedCount = nil
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
        for _ in 0..<50 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func learnAccess(from snapshot: Snapshot, afterPrompt: Bool) {
        let isNew = snapshot.after != lastReadChangeCount
        lastReadChangeCount = snapshot.after
        UserDefaults.standard.set(snapshot.after, forKey: Self.lastReadCountKey)
        // A slow read means a prompt, even if we thought pasting was allowed:
        // reading in the background must stop, and the chip must show.
        if afterPrompt || snapshot.duration > Self.promptThreshold {
            setAccess(.needsPermission)
        } else if isNew, snapshot.after != ownChangeCount {
            setAccess(.allowed)
        }
    }

    private func setAccess(_ newValue: Access) {
        NSLog("[Clipboard] setAccess %@ -> %@", access.rawValue, newValue.rawValue)
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
    }

    /// UIPasteboard's synchronous fetch blocks, on Universal Clipboard or the
    /// Allow Paste prompt. Do it on a plain dispatch queue: blocking a Swift
    /// concurrency thread on it logs "unsafeForcedSync", and the main thread
    /// must stay free so UIKit can present the keyboard. Only immutable Swift
    /// values cross back to the main actor.
    nonisolated private static func read() async -> Snapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: readClipboard())
            }
        }
    }

    nonisolated private static func readClipboard() -> Snapshot {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        let hasText = pasteboard.hasStrings || pasteboard.hasURLs
        let start = DispatchTime.now().uptimeNanoseconds
        let text = hasText ? (pasteboard.string ?? pasteboard.url?.absoluteString) : nil
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return Snapshot(
            before: before, after: pasteboard.changeCount,
            hasText: hasText, text: text, duration: elapsed
        )
    }
}
