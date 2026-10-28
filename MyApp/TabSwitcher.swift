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
/// The springs are critically damped (no overshoot) with speeds taken from
/// measuring a reference recording; see the constants below.
struct TabSwitcher: View {
    let store: BrowserStore
    /// 0 = the browser's bottom bar is showing, 1 = the switcher's. Owned by
    /// `BrowserView`, which draws both bars, so they can cross-fade.
    @Binding var barMix: Double
    /// Incremented by the bar's left button; means "go back to the current tab".
    let doneTrigger: Int
    let onSelect: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onDone: () -> Void
    /// Called the moment the exit animation starts.
    let onLeaveStart: () -> Void

    // MARK: Motion

    // A critically damped spring with angular speed w settles in roughly
    // 2*pi/w seconds, which is what SwiftUI's `duration` means when bounce is 0.
    /// The current page: w = 29 rad/s.
    private static let pageDuration = 2 * Double.pi / 29
    /// Older cards: w = 22 rad/s, a little slower than the page.
    private static let cardDuration = 2 * Double.pi / 22
    /// Leaving: w = 24 rad/s.
    private static let exitDuration = 2 * Double.pi / 24
    /// The first older card starts this long after the page does...
    private static let firstCardDelay = 0.02
    /// ...and each one further back trails the one before by this much.
    private static let cardStagger = 0.025

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
    private let currentID: Tab.ID
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
        barMix: Binding<Double>,
        doneTrigger: Int,
        onSelect: @escaping (Tab) -> Void,
        onClose: @escaping (Tab) -> Void,
        onDone: @escaping () -> Void,
        onLeaveStart: @escaping () -> Void
    ) {
        self.store = store
        _barMix = barMix
        self.doneTrigger = doneTrigger
        self.onSelect = onSelect
        self.onClose = onClose
        self.onDone = onDone
        self.onLeaveStart = onLeaveStart

        let ordered = store.tabsByRecency
        _tabs = State(initialValue: ordered)
        currentID = store.selectedTabID
        // Focus the previous tab; the current one (last) then sits at +1.
        _position = State(initialValue: CGFloat(max(0, ordered.count - 2)))
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = StackMetrics(screen: geometry.size)

            ZStack {
                Color(.systemGroupedBackground)
                    .opacity(backdrop)

                deck(metrics)
                    .allowsHitTesting(opened && leavingID == nil)
            }
        }
        .ignoresSafeArea()
        .task { await open() }
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
                    size: metrics.cardSize,
                    faviconInset: metrics.faviconInset,
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
        try? await Task.sleep(for: .milliseconds(16))
        withAnimation(.spring(duration: Self.pageDuration, bounce: 0)) {
            opened = true
            backdrop = 1
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

    private func closeCard(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let focused = Int(position.rounded())

        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
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

/// The switcher's bottom bar: a "done" button on the left, a centered capsule
/// "+" and a settings button on the right. Drawn by `BrowserView` (not by
/// `TabSwitcher`) so it can sit above the cards and cross-fade with the
/// browser's own bar.
struct SwitcherBar: View {
    let onDone: () -> Void
    let onNewTab: () -> Void
    let onSettings: () -> Void

    var body: some View {
        GeometryReader { geometry in
            HStack {
                BarButton(systemName: "display", label: "Back to page", action: onDone)

                Spacer()
                NewTabButton(width: geometry.size.width * 0.19, height: 44, action: onNewTab)
                Spacer()

                BarButton(systemName: "gearshape", label: "Settings", action: onSettings)
            }
            .padding(.horizontal, 16)
            .frame(width: geometry.size.width)
            // The button row is centered 95% of the way down the screen.
            .position(x: geometry.size.width / 2, y: geometry.size.height * 0.95)
        }
        .ignoresSafeArea()
    }
}
