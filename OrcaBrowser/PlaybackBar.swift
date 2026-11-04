import SwiftUI

/// The playback controls above the bottom bar, shown while the current tab is
/// on a YouTube watch page. The page is made shorter to leave room for it.
struct PlaybackBar: View {
    static let height: CGFloat = 44
    private static let rates = [0.5, 1, 2, 3]

    let tab: Tab

    var body: some View {
        let state = tab.playback
        HStack(spacing: 4) {
            label("\u{2212}10", name: "Back 10 seconds") { tab.send(.seek(seconds: -10)) }
            symbol(state.isPaused ? "play.fill" : "pause.fill", name: state.isPaused ? "Play" : "Pause") {
                tab.send(.togglePlay)
            }
            label("+10", name: "Forward 10 seconds") { tab.send(.seek(seconds: 10)) }
            ForEach(Self.rates, id: \.self) { rate in
                label("\(rate.formatted())\u{00D7}", name: "Speed \(rate.formatted())",
                      isOn: abs(state.rate - rate) < 0.01) { tab.send(.setRate(rate)) }
            }
            symbol("pip.enter", name: "Picture in picture") { tab.send(.pictureInPicture) }
            symbol("arrow.up.left.and.arrow.down.right", name: "Fullscreen") { tab.send(.fullscreen) }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(.bar)
    }

    private func label(_ text: String, name: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .modifier(Key(isOn: isOn))
        }
        .accessibilityLabel(name)
    }

    private func symbol(_ systemName: String, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 15, weight: .semibold)).modifier(Key(isOn: false))
        }
        .accessibilityLabel(name)
    }

    private struct Key: ViewModifier {
        let isOn: Bool

        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(isOn ? Color(.systemBackground) : Color.primary)
                .background(isOn ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.thinMaterial),
                            in: .rect(cornerRadius: 8, style: .continuous))
        }
    }
}
