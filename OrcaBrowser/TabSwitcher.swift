import OSLog
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
    /// Incremented when the store's tabs change outside the switcher; means
    /// "show the tabs as they are now".
    let reloadTrigger: Int
    let onSelect: (Tab) -> Void
    let onClose: (Tab) -> Void
    /// Flips between the normal tabs and the incognito window.
    let onToggleIncognito: () -> Void
    let onCloseIncognito: () -> Void
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
    /// Cards kept built while the deck animates away from them (see `shownRange`).
    @State private var heldRange: ClosedRange<Int>?
    /// The current page is back in the browser, and its card shows no more.
    @State private var livePageReleased = false

    /// Only cards this close to the focus are built at all. Those further
    /// away are off screen, and building them would decode their pictures:
    /// with a hundred tabs, more memory than the app is allowed.
    static let cardsBehind = 8
    static let cardsAhead = 3

    init(
        store: BrowserStore,
        barHeight: CGFloat,
        barMix: Binding<Double>,
        reloadTrigger: Int,
        onSelect: @escaping (Tab) -> Void,
        onClose: @escaping (Tab) -> Void,
        onToggleIncognito: @escaping () -> Void,
        onCloseIncognito: @escaping () -> Void,
        onLeaveStart: @escaping () -> Void
    ) {
        self.store = store
        self.barHeight = barHeight
        _barMix = barMix
        self.reloadTrigger = reloadTrigger
        self.onSelect = onSelect
        self.onClose = onClose
        self.onToggleIncognito = onToggleIncognito
        self.onCloseIncognito = onCloseIncognito
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
                    .overlay(Color.black.opacity(store.space == .incognito ? 0.6 : 0))
                    .opacity(backdrop)

                deck(metrics)
                    .allowsHitTesting(opened && leavingID == nil)
            }
            .overlay(alignment: .top) {
                // Normal tabs go into the window from the bottom bar.
                if store.space == .incognito {
                    spaceBar
                        .padding(.top, Self.windowTopInset + 8)
                        .opacity(opened && leavingID == nil ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: opened && leavingID == nil)
                }
            }
        }
        .ignoresSafeArea()
        .task { await open() }
        .onChange(of: reloadTrigger) { reload() }
    }

    // MARK: - Normal tabs and the incognito window

    /// Shown in the incognito window: a way back to the normal tabs, and a way
    /// to close all of its tabs.
    private var spaceBar: some View {
        let inWindow = store.space == .incognito
        return ZStack {
            HStack(spacing: 0) {
                spaceSegment("Tabs", systemImage: "square.on.square", isSelected: !inWindow)
                spaceSegment("Incognito", systemImage: "eye.slash.fill", isSelected: inWindow)
            }
            .padding(3)
            .background(.thinMaterial, in: .capsule)

            if inWindow {
                HStack {
                    Spacer()
                    Button(action: onCloseIncognito) {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial, in: .circle)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Close all incognito tabs")
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func spaceSegment(_ title: String, systemImage: String, isSelected: Bool) -> some View {
        Button {
            if !isSelected { onToggleIncognito() }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(isSelected ? Color.primary.opacity(0.14) : .clear, in: .capsule)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        let safeBottomInset = Self.windowBottomInset

        let shown = shownRange(around: position)
        let cards = Array(tabs.enumerated()).filter { index, tab in
            shown.contains(index) || tab.id == currentID || tab.id == leavingID
        }

        return ZStack(alignment: .topLeading) {
            ForEach(cards, id: \.element.id) { index, tab in
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
                    safeBottomInset: safeBottomInset,
                    faviconInset: metrics.faviconInset,
                    contentTop: metrics.contentTop,
                    focus: max(0, 1 - abs(relative) * 1.5),
                    showsLivePage: isCurrent && !livePageReleased,
                    onSelect: { leave(to: tab) { onSelect(tab) } },
                    onClose: { closeCard(tab) }
                )
                // Paging changes `position` every frame; only cards whose
                // inputs actually changed (the ones near focus) redraw.
                .equatable()
                .environment(\.thumbnailDelay, 400 + Int(abs(relative)) * 100)
                // Once the page is back in the browser, a card that was
                // opening onto it must not cover it with a stale picture.
                .opacity(isCurrent && isLeaving && livePageReleased ? 0 : 1)
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

    /// Indices of the cards to build: those near `position`, plus any the
    /// deck is still sliding past.
    private func shownRange(around position: CGFloat) -> ClosedRange<Int> {
        let center = Int(position.rounded())
        var low = center - Self.cardsBehind
        var high = center + Self.cardsAhead
        if let heldRange {
            low = min(low, heldRange.lowerBound)
            high = max(high, heldRange.upperBound)
        }
        return max(0, low)...max(0, high)
    }

    /// Moves the deck with an animation, keeping the cards it starts among
    /// built until it arrives, so none vanish mid-slide.
    ///
    /// Cards near the destination are built *before* the animation starts, at
    /// their places for the current position. A card first built inside the
    /// animation has no earlier pose to travel from: it would fade in at its
    /// final place while the rest of the deck is still sliding under it.
    private func move(to target: CGFloat, with animation: Animation, also change: @escaping () -> Void = {}) {
        let built = shownRange(around: position)
        let destination = shownRange(around: target)
        heldRange = min(built.lowerBound, destination.lowerBound)...max(built.upperBound, destination.upperBound)

        let animate = {
            withAnimation(animation) {
                position = target
                change()
            } completion: {
                heldRange = nil
            }
        }

        guard destination.lowerBound < built.lowerBound || destination.upperBound > built.upperBound else {
            animate()
            return
        }
        Task {
            // One frame, so the new cards are drawn at their starting places.
            try? await Task.sleep(for: .milliseconds(20))
            // A new drag took over in the meantime; it owns the position now.
            guard isHorizontalDrag == nil else {
                heldRange = nil
                return
            }
            animate()
        }
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
                InteractionBudget.shared.interacted()
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
                InteractionBudget.shared.interacted()
                defer {
                    isHorizontalDrag = nil
                    dragStartPosition = nil
                }
                guard isHorizontalDrag == true else { return }

                let start = dragStartPosition ?? position
                // "Predicted" includes momentum, so a flick can skip cards.
                let projected = start - value.predictedEndTranslation.width / metrics.pagePixels
                let target = min(max(projected.rounded(), 0), CGFloat(tabs.count - 1))

                move(to: target, with: .spring(duration: 0.45, bounce: 0.12))
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
        PerformanceTrace.signposter.emitEvent("Switcher mounted")
        await Task.yield()
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
        // Start the animation first. The selection callback activates the
        // page after it finishes; WebKit cannot hold up the first frame.
        leavingID = tab.id
        onLeaveStart()
        withAnimation(.spring(duration: Self.exitDuration, bounce: 0)) {
            leaving = true
            barMix = 0
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.exitDuration))
            // The live page goes back to the browser before the switcher fades.
            livePageReleased = true
            await Task.yield()
            finish()
        }
    }

    // MARK: - Closing a card

    /// The store's tabs changed under us: show what it has now.
    private func reload() {
        guard leavingID == nil else { return }
        let latest = store.tabsByRecency
        move(to: CGFloat(max(0, latest.count - 2)), with: .spring(duration: 0.4, bounce: 0)) {
            tabs = latest
            currentID = store.selectedTabID
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

/// The switcher's bottom bar: an incognito button on the left, a centered capsule
/// "+", and history and settings buttons on the right. Drawn by `BrowserView` (not by
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
    let onNewTab: () -> Void
    let voiceQuery: VoiceQuery
    let onVoiceSearch: (URL) -> Void
    /// The incognito window has no archive or history of its own, and the
    /// normal ones don't belong in it.
    let isInIncognitoWindow: Bool
    let onToggleIncognito: () -> Void
    let onArchive: () -> Void
    let onHistory: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // The same place flips between the two spaces: the incognito window
            // from normal tabs, and back to them from the window.
            if isInIncognitoWindow {
                BarButton(systemName: "square.on.square", label: "Normal tabs", action: onToggleIncognito)
            } else {
                BarButton(systemName: "eye.slash", label: "Incognito window", action: onToggleIncognito)
            }
            if !isInIncognitoWindow {
                BarButton(systemName: "archivebox", label: "Archive", action: onArchive)
            }

            Spacer()

            if !isInIncognitoWindow {
                BarButton(systemName: "clock", label: "History", action: onHistory)
            }
            BarButton(systemName: "gearshape", label: "Settings", action: onSettings)
        }
        // Centered on the bar, whatever sits on either side of it.
        .overlay {
            VoiceNewTabButton(width: plusButtonWidth, query: voiceQuery, onTap: onNewTab, onSearch: onVoiceSearch)
        }
        .padding(.horizontal, 20)
        // The browser bar has a 2pt progress line, then 2pt of padding, above
        // its button row.
        .padding(.top, 4)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .top)
    }
}
