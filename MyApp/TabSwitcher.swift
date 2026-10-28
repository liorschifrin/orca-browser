import SwiftUI

/// Full-screen overview of open tabs, laid out as a deck (see `StackMetrics`).
///
/// Order is by recency: the current tab is the rightmost card and the tab you
/// were on before it sits immediately to its left, and so on. So the deck
/// always opens on its last card, and there is never anything to its right.
///
/// Opening and leaving are one continuous motion. The page shrinks into its
/// card, and tapping a card makes it grow back to full screen. That motion is
/// drawn by a "hero" picture that travels between the card's rectangle and the
/// full-screen rectangle; the live page is only revealed at the very end.
struct TabSwitcher: View {
    let store: BrowserStore
    let onSelect: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onNewTab: () -> Void
    let onDone: () -> Void

    /// The tabs shown, oldest-used first. A copy taken when we open, so that
    /// picking a tab (which changes its recency) doesn't reshuffle the deck
    /// while it's fading out.
    @State private var tabs: [Tab]

    /// Which card is focused, as a continuous number: 2.0 is exactly the third
    /// card, 2.5 is halfway between the third and fourth (mid-swipe).
    @State private var position: CGFloat
    @State private var dragStartPosition: CGFloat?
    /// Whether the current drag is sideways. Decided once at the start.
    @State private var isHorizontalDrag: Bool?

    /// The tab being zoomed (nil when idle), and whether the zoom picture is
    /// currently at full-screen size (true) or at its card's size (false).
    @State private var heroID: Tab.ID?
    @State private var heroExpanded = true
    /// Fades everything except the hero: backdrop, cards, controls.
    @State private var chrome: Double = 0

    init(
        store: BrowserStore,
        onSelect: @escaping (Tab) -> Void,
        onClose: @escaping (Tab) -> Void,
        onNewTab: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.store = store
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNewTab = onNewTab
        self.onDone = onDone

        let ordered = store.tabsByRecency
        _tabs = State(initialValue: ordered)
        // The current tab is last, so start focused on the last card.
        _position = State(initialValue: CGFloat(ordered.count - 1))
        // Start with the current tab's picture covering the screen, so the
        // page doesn't visibly change as we appear.
        _heroID = State(initialValue: store.selectedTabID)
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = StackMetrics(screen: geometry.size)

            ZStack {
                Color(.systemGroupedBackground)
                    .opacity(chrome)

                VStack(spacing: 0) {
                    deck(metrics)
                    controls
                }
                .opacity(chrome)
                .allowsHitTesting(heroID == nil)

                hero(metrics)
            }
        }
        .ignoresSafeArea()
        .task { await zoomOut() }
    }

    // MARK: - The deck

    private func deck(_ metrics: StackMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                let relative = CGFloat(index) - position

                TabCard(
                    tab: tab,
                    size: metrics.cardSize,
                    focus: max(0, 1 - abs(relative) * 1.5),
                    thumbnailHidden: tab.id == heroID,
                    onSelect: { zoomIn(to: tab) { onSelect(tab) } },
                    onClose: { closeCard(tab) }
                )
                .modifier(StackEffect(relative: relative, metrics: metrics))
                // Newer cards (further right) lie on top of older ones.
                .zIndex(Double(index))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(.rect)
        .simultaneousGesture(pagingGesture(metrics))
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

    // MARK: - Controls

    /// Mirrors the browser's bottom bar so it feels like the same place.
    private var controls: some View {
        HStack {
            Text(tabs.count == 1 ? "1 Tab" : "\(tabs.count) Tabs")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            NewTabButton(action: onNewTab)

            Button("Done") {
                if let current = store.selectedTab {
                    zoomIn(to: current) { onDone() }
                } else {
                    onDone()
                }
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        // The switcher ignores safe areas, so keep clear of the home indicator.
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Zoom animation

    /// The traveling picture that does the zoom.
    @ViewBuilder
    private func hero(_ metrics: StackMetrics) -> some View {
        if let heroID, let index = tabs.firstIndex(where: { $0.id == heroID }) {
            let tab = tabs[index]
            let fullScreen = CGRect(origin: .zero, size: metrics.screen)
            let cardRect = metrics.rect(forRelative: CGFloat(index) - position)
            let rect = heroExpanded ? fullScreen : cardRect

            Group {
                if let image = tab.snapshot {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: rect.width, height: rect.height, alignment: .top)
                } else {
                    Color(.systemBackground)
                        .frame(width: rect.width, height: rect.height)
                }
            }
            .clipShape(.rect(cornerRadius: heroExpanded ? 0 : TabCard.cornerRadius, style: .continuous))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
        }
    }

    /// Opening: the full-screen page shrinks down into its card.
    private func zoomOut() async {
        // Let the deck lay out once before animating.
        try? await Task.sleep(for: .milliseconds(60))
        withAnimation(.spring(duration: 0.45, bounce: 0.05)) {
            heroExpanded = false
            chrome = 1
        } completion: {
            heroID = nil
        }
    }

    /// Leaving: a card grows to full screen, then we hand over to the live page.
    private func zoomIn(to tab: Tab, then finish: @escaping () -> Void) {
        guard heroID == nil else { return }

        // First show the hero sitting exactly on its card...
        heroExpanded = false
        heroID = tab.id

        // ...and on the next turn of the run loop, animate it outward. (If we
        // did both at once, SwiftUI would never draw the starting position.)
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.4, bounce: 0)) {
                heroExpanded = true
                chrome = 0
            } completion: {
                finish()
            }
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
