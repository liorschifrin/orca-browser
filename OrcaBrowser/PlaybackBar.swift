import SwiftUI

/// The playback controls above the bottom bar, shown while the current tab is
/// on a YouTube watch page. The page is made shorter to leave room for it.
struct PlaybackBar: View {
    static let height: CGFloat = 44
    /// Bottom row first.
    private static let rates = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3, 4]

    let tab: Tab
    var body: some View {
        let state = tab.playback
        HStack(spacing: 4) {
            qualityButton(state)
            symbol(state.captionsOn ? "captions.bubble.fill" : "captions.bubble", name: "Captions",
                   isOn: state.captionsOn) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                tab.send(.toggleCaptions)
            }
            speedButton(state)
            label("\u{2212}10", name: "Back 10 seconds") { tab.send(.seek(seconds: -10)) }
            symbol(state.isPaused ? "play.fill" : "pause.fill", name: state.isPaused ? "Play" : "Pause") {
                tab.send(.togglePlay)
            }
            label("+10", name: "Forward 10 seconds") { tab.send(.seek(seconds: 10)) }
            symbol("pip.enter", name: "Picture in picture") { tab.send(.pictureInPicture) }
            Button { tab.send(.fullscreen) } label: {
                FullscreenIcon().frame(width: 20, height: 20).modifier(PlaybackKey(isOn: false))
            }
            .accessibilityLabel("Fullscreen")
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .background(.bar)
    }

    // MARK: - Speed and quality

    private static func rateText(_ rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "\u{00D7}"
    }

    /// Shows the current speed. Touching it opens the list of speeds.
    private func speedButton(_ state: PlaybackControl.State) -> some View {
        let isNormal = abs(state.rate - 1) < 0.01
        return PopupListButton(
            items: Self.rates.map { PopupListItem(id: "\($0)", title: Self.rateText($0)) },
            selectedID: Self.rates.first { abs($0 - state.rate) < 0.01 }.map { "\($0)" },
            onSelect: { item in
                guard let rate = Double(item.id) else { return }
                tab.send(.setRate(rate))
            }
        ) {
            Text(Self.rateText(state.rate))
                .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                .modifier(PlaybackKey(isOn: !isNormal))
        }
        .accessibilityLabel("Playback speed")
        .accessibilityAddTraits(.isButton)
    }

    /// Shows the chosen quality; on Auto, also the quality Auto has picked.
    /// Touching it opens the list of the qualities this video has, with Auto
    /// at the bottom.
    private func qualityButton(_ state: PlaybackControl.State) -> some View {
        let items = [PopupListItem(id: PlaybackControl.autoQuality, title: "Auto")]
            + state.qualities.map { PopupListItem(id: $0, title: PlaybackControl.qualityName($0)) }
        return PopupListButton(
            items: items,
            selectedID: state.quality,
            onSelect: { tab.send(.setQuality($0.id)) }
        ) {
            qualityLabel(state)
                .modifier(PlaybackKey(isOn: state.quality != PlaybackControl.autoQuality))
        }
        .disabled(state.qualities.isEmpty)
        .opacity(state.qualities.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Quality")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func qualityLabel(_ state: PlaybackControl.State) -> some View {
        if state.quality != PlaybackControl.autoQuality {
            Text(PlaybackControl.qualityName(state.quality))
                .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        } else if let playing = state.playingQuality {
            VStack(spacing: 0) {
                Text("Auto").font(.system(size: 9, weight: .medium))
                Text(PlaybackControl.qualityName(playing)).font(.system(size: 12, weight: .semibold))
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        } else {
            Text("Auto").font(.system(size: 12, weight: .semibold))
        }
    }

    // MARK: - Buttons

    private func label(_ text: String, name: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .modifier(PlaybackKey(isOn: isOn))
        }
        .accessibilityLabel(name)
    }

    private func symbol(_ systemName: String, name: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 15, weight: .semibold)).modifier(PlaybackKey(isOn: isOn))
        }
        .accessibilityLabel(name)
    }
}

/// How a key on the playback bar looks.
struct PlaybackKey: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 34)
            .foregroundStyle(isOn ? Color(.systemBackground) : Color.primary)
            .background(isOn ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.thinMaterial),
                        in: .rect(cornerRadius: 8, style: .continuous))
    }
}

/// Four corner brackets, the usual fullscreen icon (the system symbols have
/// nothing like it). Drawn on a 24-point grid.
private struct FullscreenIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 24
            var path = Path()
            // Top left, top right, bottom right, bottom left.
            for corner in [
                [(3, 3), (9, 3), (9, 5), (5, 5), (5, 9), (3, 9)],
                [(15, 3), (21, 3), (21, 9), (19, 9), (19, 5), (15, 5)],
                [(19, 15), (21, 15), (21, 21), (15, 21), (15, 19), (19, 19)],
                [(3, 15), (5, 15), (5, 19), (9, 19), (9, 21), (3, 21)],
            ] {
                path.addLines(corner.map { CGPoint(x: CGFloat($0.0) * scale, y: CGFloat($0.1) * scale) })
                path.closeSubpath()
            }
            context.fill(path, with: .foreground)
        }
    }
}
