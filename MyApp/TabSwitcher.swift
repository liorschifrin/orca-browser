import SwiftUI

/// Full-screen overview of open tabs, laid out as a deck (see `StackMetrics`).
///
/// Order is by recency, oldest-used on the left and the current tab rightmost.
/// The deck opens focused on the *previous* tab, so the current tab sits one
/// card to its right, partly cropped by the screen edge.
///
/// Opening and leaving are choreographed with springs, one per group of cards:
///
///  - **Opening.** The current page doesn't shrink in place: it slides and
///    scales from full screen to its slot. Every older card starts as a tiny,
///    tilted card by the tabs button, then grows and flies out to its slot,
///    each a beat behind the one in front of it.
///  - **Leaving.** The chosen card swells to full screen over the others,
///    which stay where they are. It's quick and doesn't bounce.
///
/// The springs are critically damped (no overshoot); see the constants below.
struct TabSwitcher: View {
    let store: BrowserStore
    let barHeight: CGFloat
    /// 0 = the browser's bottom bar is showing, 1 = the switcher's. Owned by
    /// `BrowserView`, which draws both bars, so they can cross-fade.
    @Binding var barMix: Double
    /// Incremented by the bar's left button; means "go back to the current tab".
    let doneTrigger: Int
    /// Incremented when the store's tabs were replaced wholesale (Close All,
    /// Restore); means "show the tabs as they are now".
    let reloadTrigger: Int
    let onSelect: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onDone: () -> Void
    /// Called the moment the exit animation starts.
    let onLeaveStart: () -> Void

    // MARK: Motion

    // A critically damped spring with angular speed w settles in roughly
    // 2*pi/w seconds, which is what SwiftUI's `duration` means when bounce is 0.
    /// The current page.
    private static let pageDuration = 0.23
    /// Older cards, a little slower than the page.
    private static let cardDuration = 0.27
    /// Leaving.
    private static let exitDuration = 0.2
    /// The first older card starts this long after the page does...
    private static let firstCardDelay = 0.017
    /// ...and each one further back trails the one before by this much.
    private static let cardStagger = 0.017

    /// The status bar height. This view ignores the safe area, so it can't ask
    /// its own geometry; the window knows.
    private static var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }
    private static var windowBottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    // MARK: State

    /// The tabs shown, oldest-used first. A copy taken when we open, so that
    /// picking a tab (which changes its recency) doesn't reshuffle the deck
    /// while it's animating away.
    @State private var tabs: [Tab]

    /// Which card is focused, as a continuous number: 2.0 is exactly the third
    /// card, 2.5 is halfway between the third and fourth (mid-swipe).
    @State private var position: CGFloat
    @State private var dragStartPosition: CGFloat?
    /// Whether the current drag is sideways. Decided once at the start.
    @State private var isHorizontalDrag: Bool?

    /// The tab that was current when we opened.
    @State private var currentID: Tab.ID
    /// False for the first instant (everything in its starting pose), then
    /// true; flipping it is what sets the opening animation going.
    @State private var opened = false
    /// The card being opened full-screen, and whether it's on its way yet.
    @State private var leavingID: Tab.ID?
    @State private var leaving = false
    /// Opacity of the background behind the cards.
    @State private var backdrop: Double = 0

    init(
        store: BrowserStore,
        barHeight: CGFloat,
        barMix: Binding<Double>,
        doneTrigger: Int,
        reloadTrigger: Int,
        onSelect: @escaping (Tab) -> Void,
        onClose: @escaping (Tab) -> Void,
        onDone: @escaping () -> Void,
        onLeaveStart: @escaping () -> Void
    ) {
        self.store = store
        self.barHeight = barHeight
        _barMix = barMix
        self.doneTrigger = doneTrigger
        self.reloadTrigger = reloadTrigger
        self.onSelect = onSelect
        self.onClose = onClose
        self.onDone = onDone
        self.onLeaveStart = onLeaveStart

        let ordered = store.tabsByRecency
        _tabs = State(initialValue: ordered)
        _currentID = State(initialValue: store.selectedTabID)
        // Focus the previous tab; the current one (last) then sits at +1.
        _position = State(initialValue: CGFloat(max(0, ordered.count - 2)))
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = StackMetrics(screen: geometry.size, topInset: Self.windowTopInset)

            ZStack {
                Color(.systemGroupedBackground)
                    .opacity(backdrop)

                deck(metrics)
                    .allowsHitTesting(opened && leavingID == nil)
            }
        }
        .ignoresSafeArea()
        .task { await open() }
        .onChange(of: reloadTrigger) { reload() }
        .onChange(of: doneTrigger) {
            if let current = store.selectedTab {
                leave(to: current) { onDone() }
            } else {
                onDone()
            }
        }
    }

    // MARK: - The deck

    /// Changes whenever opening or leaving starts. Attached to each card's
    /// `.animation(_:value:)` so that those moments, and only those, get that
    /// card's own spring.
    private struct MotionKey: Equatable {
        var opened: Bool
        var leaving: Bool
    }

    private func deck(_ metrics: StackMetrics) -> some View {
        let currentIndex = tabs.firstIndex { $0.id == currentID } ?? tabs.count - 1

        return ZStack(alignment: .topLeading) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let relative = CGFloat(index) - position
                let isCurrent = tab.id == currentID
                let isLeaving = tab.id == leavingID
                // 0 for the card just behind the current one, 1 for the next...
                let age = max(0, currentIndex - index - 1)

                TabCard(
                    tab: tab,
                    barHeight: barHeight,
                    size: metrics.cardSize,
                    screenSize: metrics.screen,
                    safeBottomInset: Self.windowBottomInset,
                    faviconInset: metrics.faviconInset,
                    contentTop: metrics.contentTop,
                    focus: max(0, 1 - abs(relative) * 1.5),
                    onSelect: { leave(to: tab) { onSelect(tab) } },
                    onClose: { closeCard(tab) }
                )
                .modifier(StackEffect(
                    relative: relative,
                    // Older cards start tiny by the tabs button...
                    entrance: (isCurrent || opened) ? 1 : 0,
                    // ...the current page starts full screen. A card being
                    // opened ends full screen.
                    expand: isLeaving ? (leaving ? 1 : 0) : (isCurrent && !opened ? 1 : 0),
                    // Neighbors lean opposite ways, like cards tossed on a table.
                    startTilt: age.isMultiple(of: 2) ? 8 : -10,
                    metrics: metrics
                ))
                .animation(
                    motion(isCurrent: isCurrent, isLeaving: isLeaving, age: age),
                    value: MotionKey(opened: opened, leaving: leaving)
                )
                // Newer cards (further right) lie on top of older ones; the
                // card being opened lies on top of everything.
                .zIndex(isLeaving ? 1000 : Double(index))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(.rect)
        .simultaneousGesture(pagingGesture(metrics))
    }

    /// Which spring a card gets when opening or leaving starts.
    private func motion(isCurrent: Bool, isLeaving: Bool, age: Int) -> Animation? {
        if isLeaving {
            return .spring(duration: Self.exitDuration, bounce: 0)
        }
        if isCurrent {
            return .spring(duration: Self.pageDuration, bounce: 0)
        }
        let delay = Self.firstCardDelay + Self.cardStagger * Double(min(age, 6))
        return .spring(duration: Self.cardDuration, bounce: 0).delay(delay)
    }

    /// Dragging sideways moves the deck. Letting go snaps to the nearest card,
    /// with a flick carrying you further.
    private func pagingGesture(_ metrics: StackMetrics) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if isHorizontalDrag == nil {
                    isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height)
                }
                guard isHorizontalDrag == true else { return }

                let start = dragStartPosition ?? position
                dragStartPosition = start
                // Dragging right reveals older cards, i.e. lower numbers.
                position = rubberBanded(start - value.translation.width / metrics.pagePixels)
            }
            .onEnded { value in
                defer {
                    isHorizontalDrag = nil
                    dragStartPosition = nil
                }
                guard isHorizontalDrag == true else { return }

                let start = dragStartPosition ?? position
                // "Predicted" includes momentum, so a flick can skip cards.
                let projected = start - value.predictedEndTranslation.width / metrics.pagePixels
                let target = min(max(projected.rounded(), 0), CGFloat(tabs.count - 1))

                withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
                    position = target
                }
            }
    }

    /// Past either end the deck resists, like a stretched rubber band.
    private func rubberBanded(_ value: CGFloat) -> CGFloat {
        let last = CGFloat(tabs.count - 1)
        if value < 0 { return value * 0.3 }
        if value > last { return last + (value - last) * 0.3 }
        return value
    }

    // MARK: - Opening and leaving

    private func open() async {
        // Hold the starting pose for a few frames. The first draw of the deck
        // (decoding pictures, drawing shadows) is slow; doing it here, while
        // nothing is moving, keeps that cost out of the animation itself.
        try? await Task.sleep(for: .milliseconds(8))
        // The current page's card starts exactly covering the live page, so
        // the backdrop can be solid from the start. Fading it in instead
        // lets the live page show through as a ghost behind the cards.
        backdrop = 1
        withAnimation(.spring(duration: Self.pageDuration, bounce: 0)) {
            opened = true
            barMix = 1
        }
    }

    /// Swells `tab`'s card to full screen, then calls `finish`, which should
    /// remove the switcher (revealing the real page underneath).
    private func leave(to tab: Tab, then finish: @escaping () -> Void) {
        guard leavingID == nil else { return }

        guard tabs.contains(where: { $0.id == tab.id }) else {
            finish()
            return
        }
        // Restore behind the expanding card. By the time the card leaves,
        // the web view has already had the exit animation to start loading.
        tab.activate()
        tab.peek?.tab.activate()
        leavingID = tab.id
        onLeaveStart()
        withAnimation(.spring(duration: Self.exitDuration, bounce: 0)) {
            leaving = true
            barMix = 0
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.exitDuration))
            finish()
        }
    }

    // MARK: - Closing a card

    /// The store's tabs changed under us: show what it has now.
    private func reload() {
        guard leavingID == nil else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0)) {
            tabs = store.tabsByRecency
            currentID = store.selectedTabID
            position = CGFloat(max(0, tabs.count - 2))
        }
    }

    private func closeCard(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let focused = Int(position.rounded())

        withAnimation(.spring(duration: 0.22, bounce: 0)) {
            tabs.remove(at: index)
            onClose(tab)

            guard !tabs.isEmpty else { return }
            // Keep looking at the same card if a card to its left disappeared;
            // otherwise land on whichever card slid into the closed one's place.
            let newFocus = index < focused ? focused - 1 : min(focused, tabs.count - 1)
            position = CGFloat(newFocus)
        }
    }
}

/// The switcher's bottom bar: a "done" button and "close all" on the left, a
/// centered capsule "+", and "restore" and settings buttons on the right. Drawn by `BrowserView` (not by
/// `TabSwitcher`) so it can sit above the cards and cross-fade with the
/// browser's own bar.
///
/// It is laid out like `BottomBar`: same height, same side padding, and the
/// button row at the same distance from the top, so the buttons stay put
/// while the two bars cross-fade. `BrowserView` anchors it the same way too.
struct SwitcherBar: View {
    /// The browser bar's measured height.
    let height: CGFloat
    let plusButtonWidth: CGFloat
    /// False when there is nothing to close (only a blank tab is open).
    let canCloseAll: Bool
    /// How many tabs Close All has put away, waiting to be restored.
    let closedCount: Int
    let onDone: () -> Void
    let onNewTab: () -> Void
    let onCloseAll: () -> Void
    let onRestore: () -> Void
    let onHistory: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BarButton(systemName: "display", label: "Back to page", action: onDone)
            BarButton(systemName: "trash", label: "Close all tabs", action: onCloseAll)
                .disabled(!canCloseAll)
                .opacity(canCloseAll ? 1 : 0.3)

            Spacer()

            BarButton(systemName: "arrow.uturn.backward", label: "Restore closed tabs", action: onRestore)
                .disabled(closedCount == 0)
                .opacity(closedCount == 0 ? 0.3 : 1)
                .overlay(alignment: .topTrailing) {
                    if closedCount > 0 {
                        Text("\(closedCount)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: .capsule)
                            .offset(x: 6, y: -6)
                            .allowsHitTesting(false)
                    }
                }
            BarButton(systemName: "clock", label: "History", action: onHistory)
            BarButton(systemName: "gearshape", label: "Settings", action: onSettings)
        }
        // Centered on the bar, whatever sits on either side of it.
        .overlay {
            NewTabButton(width: plusButtonWidth, height: 44, action: onNewTab)
        }
        .animation(.easeOut(duration: 0.2), value: canCloseAll)
        .animation(.easeOut(duration: 0.2), value: closedCount == 0)
        .padding(.horizontal, 20)
        // The browser bar has a 2pt progress line, then 2pt of padding, above
        // its button row.
        .padding(.top, 4)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
    }
}
