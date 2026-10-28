import SwiftUI

#if DEBUG
/// A tiny debug readout of the screen's refresh rate, shown in the top-left
/// corner of debug builds only.
///
/// It runs a `CADisplayLink` (a callback the system fires once per screen
/// refresh) that asks for up to 120 per second, and counts how many actually
/// arrive. Without the `CADisableMinimumFrameDurationOnPhone` key in
/// AppInfo.plist, iPhones refuse the request and this reads 60.
///
///  - "panel" is what the hardware can do (120 on ProMotion iPhones, else 60).
///  - "now" is the measured rate over the last half second.
struct RefreshRateBadge: View {
    @State private var meter = RefreshRateMeter()

    var body: some View {
        Text("panel \(UIScreen.main.maximumFramesPerSecond) Hz · now \(meter.measured)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.7), in: .capsule)
            .foregroundStyle(meter.measured >= 100 ? .green : .orange)
            .allowsHitTesting(false)
            .onAppear { meter.start() }
            .onDisappear { meter.stop() }
    }
}

@Observable
private final class RefreshRateMeter: NSObject {
    private(set) var measured = 0

    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var windowStart: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if windowStart == 0 { windowStart = link.timestamp }
        frames += 1

        let elapsed = link.timestamp - windowStart
        if elapsed >= 0.5 {
            measured = Int((Double(frames) / elapsed).rounded())
            frames = 0
            windowStart = link.timestamp
        }
    }
}
#endif
