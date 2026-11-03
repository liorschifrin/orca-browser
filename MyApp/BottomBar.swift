import SwiftUI

/// The floating bar at the bottom of the screen.
///
///     [ tabs ]  [      +      ]  [ back ]
///     [ site name .......... settings reload ]
///
/// Everything is within thumb reach on purpose.
struct BottomBar: View {
    let tab: Tab
    let tabCount: Int
    let plusButtonWidth: CGFloat
    let onNewTab: () -> Void
    let voiceQuery: VoiceQuery
    let onEditAddress: () -> Void
    /// Called when the site settings caret in the address bar is tapped.
    let onSiteMenu: () -> Void
    let onShowTabs: () -> Void
    /// Called with the selected destination address for a finished voice search.
    let onVoiceSearch: (URL) -> Void

    @State private var plusButtonFrame = CGRect.zero
    @State private var backButtonFrame = CGRect.zero
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            ProgressLine(tab: tab)

            VStack(spacing: 2) {
                HStack(spacing: 12) {
                    TabSwitcherButton(count: tabCount, action: onShowTabs)

                    #if DEBUG
                    if AppSettings.shared.showDebugStats {
                        DebugStatsAnchor()
                    }
                    #endif

                    Spacer()

                    HistoryBackButton(tab: tab, showHistory: $showHistory)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named("browserToolbar"))
                        } action: { backButtonFrame = $0 }
                }
                // Centered on the bar, whatever sits on either side of it.
                .overlay {
                    VoiceNewTabButton(width: plusButtonWidth, query: voiceQuery, onTap: onNewTab, onSearch: onVoiceSearch)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named("browserToolbar"))
                        } action: { plusButtonFrame = $0 }
                }

                siteCapsule
                    // Clear the screen's rounded bottom corners.
                    .padding(.horizontal, 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 0)
        }
        // The blurred strip extends down under the home indicator.
        .background(.bar)
        // No `.contentShape(.rect)` here: it would limit touches to the bar's
        // own rectangle, and the history list floats above it.
        .coordinateSpace(name: "browserToolbar")
        // Off while the history list is open, so the swipe can't compete with
        // (or cancel) the touches that pick an entry from it.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20, coordinateSpace: .named("browserToolbar"))
                .onEnded { value in
                    // Drags starting on + belong to voice search; Back owns
                    // its history menu, even when the finger moves outside.
                    guard !plusButtonFrame.insetBy(dx: -8, dy: -8).contains(value.startLocation),
                          !backButtonFrame.insetBy(dx: -8, dy: -8).contains(value.startLocation),
                          value.translation.height < -30,
                          -value.translation.height > abs(value.translation.width) else { return }
                    onShowTabs()
                },
            including: showHistory ? .subviews : .all
        )
    }

    private var siteCapsule: some View {
        ZStack {
            // Tapping the capsule edits the address.
            Button(action: onEditAddress) {
                Color.clear.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit Address")

            Text(tab.displayName)
                .allowsHitTesting(false)
                .font(.caption.weight(.medium))
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
                // Only web pages have a site to configure.
                if ContentBlocker.site(for: tab.url) != nil {
                    siteSettingsButton
                }
                reloadButton
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(.thinMaterial, in: .capsule)
    }

    private var siteSettingsButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
            onSiteMenu()
        } label: {
            CapsuleIcon(systemName: "chevron.up")
        }
        .accessibilityLabel("Site Settings")
    }

    private var reloadButton: some View {
        Group {
            Button {
                tab.isLoading ? tab.stopLoading() : tab.reload()
            } label: {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 24, height: 24)
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
enum AddToPlay {
    /// Must match the shortcut's name in the Shortcuts app exactly.
    static let shortcutName = "Add Video to Play"

    @MainActor
    static func run(with url: URL) {
        UIPasteboard.general.url = url

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
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
    }
}

private struct AddToPlayButton: View {
    let url: URL
    @State private var didRun = false

    var body: some View {
        Button {
            flash($didRun)
            AddToPlay.run(with: url)
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
            .frame(width: 24, height: 24)
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
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
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
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
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
///
/// Reads the tab itself, so progress updates redraw only this line rather
/// than the whole bar. Grows by scaling, which (unlike changing its width)
/// doesn't re-run layout on every animation frame.
private struct ProgressLine: View {
    let tab: Tab

    var body: some View {
        Rectangle()
            .fill(.tint)
            .scaleEffect(x: tab.progress, anchor: .leading)
            .animation(.easeOut(duration: 0.2), value: tab.progress)
            .frame(height: 2)
            .opacity(tab.isLoading ? 1 : 0)
            .animation(.easeOut(duration: 0.3), value: tab.isLoading)
    }
}
