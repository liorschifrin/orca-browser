import Foundation
import Observation
import UIKit

/// Keeps clipboard fetching independent of the search overlay's lifetime.
@MainActor
@Observable
final class ClipboardCache {
    static let shared = ClipboardCache()

    private(set) var text = ""
    @ObservationIgnored private var cachedChangeCount = -1
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private init() {}

    /// Forgets what was on the clipboard, for when it has just been emptied.
    func clear() {
        refreshTask?.cancel()
        refreshTask = nil
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
        refreshTask = Task {
            defer { refreshTask = nil }
            // Retry transient empty reads without making the user reopen search.
            for attempt in 0..<4 {
                let snapshot = await Task.detached(priority: .userInitiated) {
                    Self.readClipboard()
                }.value
                if snapshot.before == snapshot.after {
                    if let value = snapshot.text {
                        text = value
                        cachedChangeCount = snapshot.after
                    } else if !snapshot.hasText {
                        text = ""
                        cachedChangeCount = snapshot.after
                    }
                    if cachedChangeCount == UIPasteboard.general.changeCount { return }
                }
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
                }
            }
        }
    }

    private struct Snapshot: Sendable {
        let before: Int
        let after: Int
        let hasText: Bool
        let text: String?
    }

    /// UIPasteboard's synchronous fetch can wait for Universal Clipboard.
    /// Keep that work off the main thread so UIKit can present the keyboard.
    /// Only immutable Swift values cross back to the main actor.
    nonisolated private static func readClipboard() -> Snapshot {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        let hasText = pasteboard.hasStrings || pasteboard.hasURLs
        let text = hasText ? (pasteboard.string ?? pasteboard.url?.absoluteString) : nil
        return Snapshot(before: before, after: pasteboard.changeCount, hasText: hasText, text: text)
    }
}
