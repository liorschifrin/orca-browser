import SwiftUI

/// The floating bar at the bottom of the screen.
///
///     [ site name ................ reload ]
///     [ (switcher) ]  [   +   ]  [  back  ]
///
/// The bottom-left slot is reserved for the tab switcher (a later milestone).
/// Everything is within thumb reach on purpose.
struct BottomBar: View {
    let tab: Tab
    let onNewTab: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ProgressLine(progress: tab.progress, isVisible: tab.isLoading)

            VStack(spacing: 10) {
                siteCapsule

                HStack {
                    // Placeholder so the + stays centered until the switcher exists.
                    Color.clear.frame(width: 44, height: 44)

                    Spacer()
                    newTabButton
                    Spacer()

                    BarButton(systemName: "chevron.left", label: "Back") {
                        tab.goBack()
                    }
                    .disabled(!tab.canGoBack)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        // The blurred strip extends down under the home indicator.
        .background(.bar)
    }

    // MARK: - Pieces

    private var newTabButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onNewTab()
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: 160, height: 48)
                .background(.thinMaterial, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("New Tab")
    }

    private var siteCapsule: some View {
        HStack {
            Text(displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                // Balances the reload button so the text is truly centered.
                .padding(.leading, 32)

            Button {
                tab.isLoading ? tab.stopLoading() : tab.reload()
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .disabled(tab.isBlank)
            .accessibilityLabel(tab.isLoading ? "Stop" : "Reload")
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .background(.thinMaterial, in: .capsule)
    }

    /// "www.apple.com" -> "apple.com". Falls back to the title, then a hint.
    private var displayName: String {
        if let host = (tab.url ?? tab.loadError?.failedURL)?.host() {
            return host.replacing("www.", with: "", maxReplacements: 1)
        }
        return tab.title ?? "New Tab"
    }
}

/// A round 44pt button (44pt is Apple's minimum comfortable tap size).
struct BarButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: .circle)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }
}

/// Shrinks slightly while pressed, so taps feel physical.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// A thin bar along the top edge of the toolbar that fills as the page loads.
private struct ProgressLine: View {
    let progress: Double
    let isVisible: Bool

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.tint)
                .frame(width: geometry.size.width * progress)
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .frame(height: 2)
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: isVisible)
    }
}
