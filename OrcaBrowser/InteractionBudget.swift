import Foundation
import OSLog

/// Optional work yields to startup, page gestures, search, and transitions.
/// Waiting suspends tasks; it never occupies the main thread.
@MainActor
final class InteractionBudget {
    static let shared = InteractionBudget()
    private let startupDeadline: ContinuousClock.Instant

    init(startupDelay: Duration = .seconds(3)) {
        startupDeadline = .now.advanced(by: startupDelay)
    }
    private var quietDeadline = ContinuousClock.now
    var isForeground = true
    var isSearching = false
    var isSwitching = false

    func interacted() {
        quietDeadline = .now.advanced(by: .milliseconds(500))
    }

    func isIdle(allowSwitcher: Bool = false) -> Bool {
        let now = ContinuousClock.now
        return isForeground && !isSearching && (allowSwitcher || !isSwitching)
            && now >= startupDeadline && now >= quietDeadline
    }

    func waitForIdle(allowSwitcher: Bool = false) async throws {
        while true {
            try Task.checkCancellation()
            if isIdle(allowSwitcher: allowSwitcher) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Inspect these intervals alongside Animation Hitches in Instruments.
enum PerformanceTrace {
    static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "OrcaBrowser", category: "Responsiveness")
}
