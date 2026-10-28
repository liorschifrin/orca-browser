import SwiftUI

/// The floating bar at the bottom of the screen: back button, plus a capsule
/// showing the site and a reload/stop button. (The + and tab switcher join it
/// in later milestones.)
struct BottomBar: View {
    let tab: Tab

    var body: some View {
        VStack(spacing: 0) {
            ProgressLine(progress: tab.progress, isVisible: tab.isLoading)

            HStack(spacing: 12) {
                BarButton(systemName: "chevron.left", label: "Back") {
                    tab.goBack()
                }
                .disabled(!tab.canGoBack)

                // The site capsule.
                HStack {
                    Text(displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)

                    Button {
                        tab.isLoading ? tab.stopLoading() : tab.reload()
                    } label: {
                        Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel(tab.isLoading ? "Stop" : "Reload")
                }
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .frame(height: 44)
                .background(.thinMaterial, in: .capsule)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        // The blurred strip extends down under the home indicator.
        .background(.bar)
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
        .accessibilityLabel(label)
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
