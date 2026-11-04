import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

/// Keeps clipboard fetching independent of the search overlay's lifetime.
/// Whatever it reads is also remembered in `ClipboardHistory`.
@MainActor
@Observable
final class ClipboardCache {
    static let shared = ClipboardCache()

    private(set) var text = ""
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
    /// The pasteboard change made by the history itself (an item copied back).
    @ObservationIgnored private var ownChangeCount = -1
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Tells a refresh that was cancelled by `clear()` apart from the one
    /// that replaced it, when it finally winds down.
    @ObservationIgnored private var refreshGeneration = 0

    private init() {}

    /// Forgets what was on the clipboard, for when it has just been emptied.
    func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        text = ""
        cachedChangeCount = -1
    }

    func refresh() {
        // Opening search or receiving another clipboard notification must not
        // cancel an in-flight Universal Clipboard fetch and start it over.
        guard refreshTask == nil else { return }
        let count = UIPasteboard.general.changeCount
        guard count != cachedChangeCount else { return }
        text = ""
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task {
            defer { if generation == refreshGeneration { refreshTask = nil } }
            // Retry transient empty reads without making the user reopen search.
            for attempt in 0..<4 {
                let snapshot = await Task.detached(priority: .userInitiated) {
                    Self.readClipboard()
                }.value
                // Cleared meanwhile (Incognito closed): what was read may be
                // private, so neither show it nor remember it.
                guard !Task.isCancelled else { return }
                if snapshot.before == snapshot.after {
                    // Still fetching (Universal Clipboard) if the pasteboard
                    // says there's text or a picture but it came back empty.
                    let isComplete = (!snapshot.hasText || snapshot.text != nil)
                        && (!snapshot.wantsImage || snapshot.image != nil)
                    if isComplete {
                        text = snapshot.text ?? ""
                        lastTypes = snapshot.types
                        lastWasConcealed = snapshot.isConcealed
                        cachedChangeCount = snapshot.after
                        remember(snapshot)
                    } else if let value = snapshot.text {
                        // A picture is still arriving; the text needn't wait.
                        text = value
                    }
                    if cachedChangeCount == UIPasteboard.general.changeCount { return }
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
                }
            }
        }
    }

    /// The pasteboard was just written by `ClipboardHistory`; don't record it again.
    func ignoreCurrentChange() {
        ownChangeCount = UIPasteboard.general.changeCount
    }

    private func remember(_ snapshot: Snapshot) {
        guard snapshot.after != ownChangeCount, Self.shouldRemember(
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

    private struct Snapshot: Sendable {
        let before: Int
        let after: Int
        let hasText: Bool
        let text: String?
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

    /// UIPasteboard's synchronous fetch can wait for Universal Clipboard.
    /// Keep that work off the main thread so UIKit can present the keyboard.
    /// Only immutable Swift values cross back to the main actor.
    nonisolated private static func readClipboard() -> Snapshot {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        let isConcealed = pasteboard.contains(pasteboardTypes: [concealedType])
        let hasText = pasteboard.hasStrings || pasteboard.hasURLs
        let text = hasText ? (pasteboard.string ?? pasteboard.url?.absoluteString) : nil
        // Copying a picture from a page also puts its address on the
        // clipboard; the picture is what was meant.
        let wantsImage = !pasteboard.hasStrings && pasteboard.hasImages
        let image = wantsImage ? readImage(pasteboard) : nil
        return Snapshot(
            before: before, after: pasteboard.changeCount, hasText: hasText, text: text,
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
