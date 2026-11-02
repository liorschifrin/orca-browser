import SwiftUI

#if DEBUG
/// Current frames per second and memory footprint, for debug builds. Shown
/// in the bottom bar between the tab switcher and the new tab button, and
/// carried below the card deck while the tab switcher is open (see
/// `DebugStatsTracker`).
struct DebugStats: View {
    @State private var meter = FrameMeter()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(meter.fps) fps")
            Text("\(meter.memoryMB) MB")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
        .fixedSize()
        .allowsHitTesting(false)
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
        .accessibilityHidden(true)
    }
}

/// Reserves the indicator's spot in the bottom bar and reports where it is.
/// The real indicator is drawn by `DebugStatsTracker`, above both screens,
/// so the one meter keeps running while it moves between the two.
struct DebugStatsAnchor: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("000 fps")
            Text("000 MB")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .fixedSize()
        .hidden()
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: DebugStatsHomeKey.self, value: geometry.frame(in: .global))
            }
        }
    }
}

struct DebugStatsHomeKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The indicator itself: sits at `home` (in the bottom bar) when `mix` is 0
/// and glides to just under the focused card when `mix` is 1. `mix` is the
/// same value that cross-fades the two bars, so it moves with their springs.
struct DebugStatsTracker: View {
    let home: CGRect
    let mix: Double

    var body: some View {
        GeometryReader { geometry in
            let metrics = StackMetrics(screen: geometry.size)
            let target = CGPoint(x: geometry.size.width / 2, y: metrics.rect(forRelative: 0).maxY + 24)
            DebugStats()
                .position(
                    x: home.midX + (target.x - home.midX) * mix,
                    y: home.midY + (target.y - home.midY) * mix
                )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(home == .zero ? 0 : 1)
    }
}

/// Counts display refreshes once a second, and reads the app's memory use.
@MainActor @Observable
private final class FrameMeter {
    private(set) var fps = 0
    private(set) var memoryMB = 0

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var windowStart: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        frames = 0
        windowStart = 0
        let link = CADisplayLink(target: Ticker { [weak self] timestamp in
            self?.tick(timestamp)
        }, selector: #selector(Ticker.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        memoryMB = Self.footprintMB()
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    private func tick(_ timestamp: CFTimeInterval) {
        if windowStart == 0 { windowStart = timestamp }
        frames += 1
        let elapsed = timestamp - windowStart
        guard elapsed >= 1 else { return }
        fps = Int((Double(frames) / elapsed).rounded())
        memoryMB = Self.footprintMB()
        frames = 0
        windowStart = timestamp
    }

    /// The app's own memory as Xcode's gauge counts it (`phys_footprint`).
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / 1_048_576)
    }

    /// CADisplayLink retains its target, so it gets this instead of the meter.
    private final class Ticker: NSObject {
        let handler: @MainActor (CFTimeInterval) -> Void
        init(_ handler: @escaping @MainActor (CFTimeInterval) -> Void) { self.handler = handler }
        @objc func fire(_ link: CADisplayLink) {
            let timestamp = link.timestamp
            MainActor.assumeIsolated { handler(timestamp) }
        }
    }
}
#endif
