import SwiftUI
import WebKit

/// The floating bar at the bottom of the screen.
///
///     [ tabs ]  [      +      ]  [ mic ][ back ]
///     [ site name .......... settings reload ]
///
/// Everything is within thumb reach on purpose.
struct BottomBar: View {
    let tab: Tab
    let tabCount: Int
    let plusButtonWidth: CGFloat
    let onNewTab: () -> Void
    let onEditAddress: () -> Void
    /// Called when the site settings caret in the address bar is tapped.
    let onSiteMenu: () -> Void
    let onShowTabs: () -> Void
    /// Called with the Google search address for a finished voice search.
    let onVoiceSearch: (URL) -> Void

    @State private var voiceSearch = VoiceSearch()
    @State private var micTouchStart = CGPoint.zero
    /// The touch has held still long enough to be sure it's not a swipe;
    /// only then does the microphone show (and buzz) that it's listening.
    @State private var isMicConfirmed = false
    @State private var micConfirmTask: Task<Void, Never>?
    @State private var isMicTouchIgnored = false
    @State private var backButtonFrame = CGRect.zero
    @State private var showHistory = false
    @State private var isBackPressed = false
    @State private var highlighted: Int?
    @State private var holdTask: Task<Void, Never>?
    @State private var didMove = false
    @State private var ignoreTouch = false
    @State private var isHistoryPinned = false
    @State private var listFrame = CGRect.zero
    @State private var feedback = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        VStack(spacing: 0) {
            ProgressLine(progress: tab.progress, isVisible: tab.isLoading)

            VStack(spacing: 2) {
                HStack(spacing: 12) {
                    TabSwitcherButton(count: tabCount, action: onShowTabs)

                    #if DEBUG
                    if AppSettings.shared.showDebugStats {
                        DebugStats()
                    }
                    #endif

                    Spacer()

                    voiceButton
                    backButton
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named("browserToolbar"))
                        } action: { backButtonFrame = $0 }
                }
                // Centered on the bar, whatever sits on either side of it.
                .overlay {
                    NewTabButton(width: plusButtonWidth, height: 44, action: onNewTab)
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
                    // A drag that starts at Back belongs to its history menu,
                    // even if the finger later moves outside the button.
                    guard !backButtonFrame.insetBy(dx: -8, dy: -8).contains(value.startLocation),
                          value.translation.height < -30,
                          -value.translation.height > abs(value.translation.width) else { return }
                    onShowTabs()
                },
            including: showHistory ? .subviews : .all
        )
        .cancelsVoiceSearchWhenInterrupted(voiceSearch)
        .onChange(of: voiceSearch.state) {
            if voiceSearch.state == .idle { isMicConfirmed = false }
        }
        .alert("Voice search", isPresented: Binding(
            get: { voiceSearch.errorMessage != nil },
            set: { if !$0 { voiceSearch.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { voiceSearch.errorMessage = nil }
        } message: {
            Text(voiceSearch.errorMessage ?? "")
        }
    }

    /// Hold to talk, let go to Google search what was said. Recording starts
    /// the instant the finger lands (the touch is read straight from UIKit),
    /// but the button only shows it, with a buzz, once the finger has held
    /// still for a moment. A touch that moves first is a swipe: it's dropped
    /// silently and left to the toolbar's swipe, which opens the tab switcher.
    private var voiceButton: some View {
        let isRecording = voiceSearch.state == .recording && isMicConfirmed
        return ZStack {
            if isMicConfirmed, voiceSearch.state == .transcribing || voiceSearch.state == .downloading {
                ProgressView()
            } else {
                Image(systemName: isRecording ? "mic.fill" : "mic")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isRecording ? Color.red : Color.primary)
            }
        }
        .frame(width: 44, height: 44)
        .background(.thinMaterial, in: .circle)
        .contentShape(.circle)
        .scaleEffect(isRecording ? 1.12 : 1)
        .animation(.spring(duration: 0.2), value: isRecording)
        .overlay(alignment: .bottomTrailing) {
            if isMicConfirmed, let status = voiceSearch.status {
                Text(status)
                    .font(.subheadline)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(12)
                    .background(.regularMaterial, in: .capsule)
                    .offset(y: -(44 + Self.historyGap))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            TouchSurface(
                onBegan: { point in
                    micTouchStart = point
                    isMicTouchIgnored = false
                    isMicConfirmed = false
                    // Record at once; whether it's a swipe is decided meanwhile.
                    voiceSearch.begin(provider: AppSettings.shared.voiceSearchProvider)
                    micConfirmTask?.cancel()
                    micConfirmTask = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled, voiceSearch.isBusy else { return }
                        isMicConfirmed = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                },
                onMoved: { point in
                    guard !isMicTouchIgnored, !isMicConfirmed,
                          hypot(point.x - micTouchStart.x, point.y - micTouchStart.y) > 10 else { return }
                    // Moved before it was sure to be a hold: a swipe.
                    micConfirmTask?.cancel()
                    isMicTouchIgnored = true
                    voiceSearch.cancel()
                },
                onEnded: { point in
                    micConfirmTask?.cancel()
                    if isMicTouchIgnored { return }
                    let dx = point.x - micTouchStart.x
                    let dy = point.y - micTouchStart.y
                    if dy < -30, -dy > abs(dx) {
                        voiceSearch.cancel()
                    } else {
                        finishVoiceSearch()
                    }
                },
                onCancelled: {
                    micConfirmTask?.cancel()
                    voiceSearch.cancel()
                }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Voice search")
        .accessibilityHint("Hold while speaking, then release to Google search. With VoiceOver, double-tap to start and again to search.")
        .accessibilityValue(isRecording ? "Listening" : "Hold to talk")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if voiceSearch.state == .recording {
                finishVoiceSearch()
            } else {
                isMicConfirmed = true
                voiceSearch.begin(provider: AppSettings.shared.voiceSearchProvider)
            }
        }
    }

    private func finishVoiceSearch() {
        voiceSearch.finish { transcript in
            guard let url = Destination.searchURL(for: transcript) else { return }
            onVoiceSearch(url)
        }
    }

    private static let historyRowHeight: CGFloat = 40
    private static let historyWidth: CGFloat = 260
    private static let historyMaxRows = 11
    /// Space between the top of the button and the bottom of the list.
    private static let historyGap: CGFloat = 8

    /// Tap to go back one page. Press and hold (or drag up) to open the
    /// tab's whole history above the button: oldest page at the bottom,
    /// newest at the top, the current page dark. Slide to an entry and let
    /// go to jump there (backward or forward). Letting go elsewhere leaves
    /// the list open for another touch.
    private var backButton: some View {
        Image(systemName: "chevron.left")
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.thinMaterial, in: .circle)
            .contentShape(.circle)
            .scaleEffect(isBackPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: isBackPressed)
            .opacity(tab.canGoBack || tab.canGoForward ? 1 : 0.3)
            .overlay(alignment: .bottomTrailing) {
                if showHistory {
                    historyList
                        .offset(y: -(44 + Self.historyGap))
                        .transition(.opacity)
                        .allowsHitTesting(isHistoryPinned)
                }
            }
            // While pinned open, any touch outside the list closes it, and
            // still carries on to whatever it landed on.
            .background {
                OutsideTouchCloser(isActive: isHistoryPinned, insideFrame: listFrame) {
                    closeHistory()
                }
            }
            // Raw touches, handled by UIKit: SwiftUI's gestures can wait
            // before reporting a finger that is held still.
            .overlay {
                TouchSurface(
                    onBegan: { _ in touchBegan() },
                    onMoved: { point in touchMoved(to: point) },
                    onEnded: { point in touchEnded(at: point) },
                    onCancelled: { cancelTouch() }
                )
            }
            .accessibilityElement()
            .accessibilityLabel("Back")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if tab.canGoBack { tab.goBack() } }
    }

    private func touchBegan() {
        // Touching the button while the list is pinned just closes it.
        if isHistoryPinned {
            closeHistory()
            ignoreTouch = true
            return
        }
        ignoreTouch = false
        isBackPressed = true
        didMove = false
        feedback.prepare()
        holdTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            openHistory()
        }
    }

    private func touchMoved(to point: CGPoint) {
        if ignoreTouch { return }
        // Dragging off the button opens it without waiting.
        if !showHistory, hypot(point.x - 22, point.y - 22) > 14 {
            didMove = true
            holdTask?.cancel()
            openHistory()
        }
        if showHistory { updateHighlight(at: point) }
    }

    private func touchEnded(at point: CGPoint) {
        if ignoreTouch { return }
        holdTask?.cancel()
        isBackPressed = false
        if showHistory {
            if let index = historyIndex(at: point) {
                jump(toRow: index)
            } else {
                // Let go away from the entries: leave the list open to pick from.
                highlighted = nil
                isHistoryPinned = true
            }
        } else if !didMove, tab.canGoBack {
            tab.goBack()
        }
    }

    private func cancelTouch() {
        holdTask?.cancel()
        isBackPressed = false
        closeHistory()
    }

    private func jump(toRow index: Int) {
        let window = historyWindow
        if window.items.indices.contains(index) {
            tab.go(to: window.items[index])
        }
        closeHistory()
    }

    private func closeHistory() {
        isHistoryPinned = false
        highlighted = nil
        withAnimation(.easeOut(duration: 0.12)) { showHistory = false }
    }

    /// The slice of history that fits on screen, oldest first, kept around
    /// the current page. `current` is its index within `items`.
    private var historyWindow: (items: [WKBackForwardListItem], start: Int, current: Int) {
        let (items, current) = tab.history
        let rows = Self.historyMaxRows
        let start = max(0, min(current - rows / 2, items.count - rows))
        let end = min(items.count, start + rows)
        return (Array(items[start..<end]), start, current - start)
    }

    private func openHistory() {
        guard !showHistory, tab.history.items.count > 1 else { return }
        feedback.impactOccurred()
        highlighted = nil
        withAnimation(.easeOut(duration: 0.12)) { showHistory = true }
    }

    /// Which row is under the finger (0 = bottom row). `point` is relative
    /// to the button.
    private func historyIndex(at point: CGPoint) -> Int? {
        guard point.x > 44 - Self.historyWidth - 20, point.x < 44 + 20 else { return nil }
        let above = -point.y - Self.historyGap
        guard above >= 0 else { return nil }
        let index = Int(above / Self.historyRowHeight)
        return index < historyWindow.items.count ? index : nil
    }

    private func updateHighlight(at point: CGPoint) {
        updateHighlight(toRowAt: historyIndex(at: point))
    }

    private func updateHighlight(toRowAt index: Int?) {
        if index != highlighted {
            highlighted = index
            if index != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    private var historyList: some View {
        let window = historyWindow
        // Reversed so the oldest page is at the bottom, the newest on top.
        return VStack(spacing: 0) {
            ForEach(Array(window.items.enumerated()).reversed(), id: \.offset) { index, item in
                let isCurrent = index == window.current
                Text(item.title?.isEmpty == false ? item.title! : item.url.host() ?? item.url.absoluteString)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(width: Self.historyWidth, height: Self.historyRowHeight, alignment: .leading)
                    .background {
                        if isCurrent {
                            Color.black.opacity(0.75)
                        } else if index == highlighted {
                            Color.accentColor.opacity(0.35)
                        }
                    }
            }
        }
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listFrame = $0 }
        // Once pinned, touches on the list itself: slide to highlight,
        // let go to jump (or just tap an entry).
        .overlay {
            if isHistoryPinned {
                TouchSurface(
                    onBegan: { point in updateHighlight(toRowAt: pinnedRow(at: point)) },
                    onMoved: { point in updateHighlight(toRowAt: pinnedRow(at: point)) },
                    onEnded: { point in
                        if let row = pinnedRow(at: point) { jump(toRow: row) } else { highlighted = nil }
                    },
                    onCancelled: { highlighted = nil }
                )
            }
        }
    }

    /// Row (0 = bottom) under a point relative to the list, or nil if outside it.
    private func pinnedRow(at point: CGPoint) -> Int? {
        let count = historyWindow.items.count
        let height = CGFloat(count) * Self.historyRowHeight
        guard point.x >= 0, point.x <= Self.historyWidth, point.y >= 0, point.y <= height else { return nil }
        return min(count - 1, Int((height - point.y) / Self.historyRowHeight))
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
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
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

/// While active, watches every touch on screen without getting in its way,
/// and calls `onOutside` for those that start outside `insideFrame`
/// (in screen coordinates).
private struct OutsideTouchCloser: UIViewRepresentable {
    let isActive: Bool
    let insideFrame: CGRect
    let onOutside: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.insideFrame = insideFrame
        coordinator.onOutside = onOutside
        // The view may not be in a window yet; look again next pass.
        DispatchQueue.main.async {
            if isActive, let window = view.window {
                coordinator.attach(to: window)
            } else {
                coordinator.detach()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var insideFrame = CGRect.zero
        var onOutside: () -> Void = {}
        private var recognizer: Observer?

        func attach(to window: UIWindow) {
            guard recognizer == nil else { return }
            let observer = Observer { [weak self] point in
                guard let self, !self.insideFrame.contains(point) else { return }
                // Later, so a touch on the back button itself is handled first.
                DispatchQueue.main.async { self.onOutside() }
            }
            window.addGestureRecognizer(observer)
            recognizer = observer
        }

        func detach() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }
    }

    /// Looks at each new touch, then steps aside (fails) so nothing else is affected.
    final class Observer: UIGestureRecognizer {
        private let handler: (CGPoint) -> Void

        init(handler: @escaping (CGPoint) -> Void) {
            self.handler = handler
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { handler(touch.location(in: nil)) }
            state = .failed
        }
    }
}

/// A transparent view that reports touches straight from UIKit, with
/// positions relative to itself (also while the finger is outside it).
private struct TouchSurface: UIViewRepresentable {
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    func makeUIView(context: Context) -> TouchView { TouchView() }

    func updateUIView(_ view: TouchView, context: Context) {
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onCancelled = onCancelled
    }

    final class TouchView: UIView {
        var onBegan: (CGPoint) -> Void = { _ in }
        var onMoved: (CGPoint) -> Void = { _ in }
        var onEnded: (CGPoint) -> Void = { _ in }
        var onCancelled: () -> Void = {}

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first { onBegan(touch.location(in: self)) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first { onMoved(touch.location(in: self)) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first { onEnded(touch.location(in: self)) }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onCancelled() }
    }
}
