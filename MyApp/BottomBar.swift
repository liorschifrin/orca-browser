import SwiftUI

/// The floating bar at the bottom of the screen.
///
///     [ site name ................ reload ]
///     [ tabs ]  [      +      ]  [  back  ]
///
/// Everything is within thumb reach on purpose.
struct BottomBar: View {
    let tab: Tab
    let tabCount: Int
    let onNewTab: () -> Void
    let onShowTabs: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ProgressLine(progress: tab.progress, isVisible: tab.isLoading)

            VStack(spacing: 10) {
                siteCapsule

                HStack {
                    TabSwitcherButton(count: tabCount, action: onShowTabs)

                    Spacer()
                    NewTabButton(action: onNewTab)
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

    private var siteCapsule: some View {
        ZStack {
            Text(tab.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                // Keeps the name clear of the buttons on either side.
                .padding(.horizontal, 72)

            HStack(spacing: 0) {
                if let url = tab.url {
                    CopyURLButton(url: url)
                    if tab.isYouTube {
                        AddToPlayButton(url: url)
                    }
                }
                Spacer()
                reloadButton
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .background(.thinMaterial, in: .capsule)
    }

    private var reloadButton: some View {
        Group {
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
    }
}

/// Copies the page address to the clipboard, with a brief checkmark.
private struct CopyURLButton: View {
    let url: URL
    @State private var didCopy = false

    var body: some View {
        Button {
            UIPasteboard.general.url = url
            flash($didCopy)
        } label: {
            CapsuleIcon(systemName: didCopy ? "checkmark" : "doc.on.doc")
        }
        .accessibilityLabel("Copy Link")
    }
}

/// Copies the address, then runs the "Add Video to Play" shortcut with it.
/// Only shown on YouTube. iOS briefly switches to the Shortcuts app to run it,
/// then Shortcuts hands control back through the app's arcbrowser:// address.
private struct AddToPlayButton: View {
    /// Must match the shortcut's name in the Shortcuts app exactly.
    static let shortcutName = "Add Video to Play"

    let url: URL
    @State private var didRun = false

    var body: some View {
        Button {
            UIPasteboard.general.url = url
            flash($didRun)

            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "x-callback-url"
            components.path = "/run-shortcut"
            components.queryItems = [
                URLQueryItem(name: "name", value: Self.shortcutName),
                URLQueryItem(name: "input", value: "text"),
                URLQueryItem(name: "text", value: url.absoluteString),
                // Shortcuts returns here when done (or cancelled).
                URLQueryItem(name: "x-success", value: "arcbrowser://"),
                URLQueryItem(name: "x-cancel", value: "arcbrowser://"),
                URLQueryItem(name: "x-error", value: "arcbrowser://"),
            ]
            if let shortcutURL = components.url {
                UIApplication.shared.open(shortcutURL)
            }
        } label: {
            CapsuleIcon(systemName: didRun ? "checkmark" : "text.badge.plus")
        }
        .accessibilityLabel("Add Video to Play")
    }
}

private struct CapsuleIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.footnote.weight(.semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 32, height: 32)
            .contentShape(.rect)
    }
}

/// Confirms a tap: a small haptic, and `flag` is true for a second.
@MainActor
private func flash(_ flag: Binding<Bool>) {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    withAnimation { flag.wrappedValue = true }
    Task {
        try? await Task.sleep(for: .seconds(1))
        withAnimation { flag.wrappedValue = false }
    }
}

/// The big center pill. Also used on the tab switcher screen.
struct NewTabButton: View {
    var width: CGFloat = 160
    var height: CGFloat = 48
    let action: () -> Void

    var body: some View {
        Button {
            // .soft is a gentler, rounder tap than .light; intensity is 0...1.
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
            action()
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .frame(width: width, height: height)
                .background(.thinMaterial, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("New Tab")
    }
}

/// Bottom-left button: a rounded square showing how many tabs are open.
struct TabSwitcherButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
            action()
        } label: {
            Text("\(count)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(width: 44, height: 44)
                .background(.thinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Tabs, \(count) open")
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
