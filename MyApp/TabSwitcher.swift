import SwiftUI

/// Remembers where each card's thumbnail is. A class (not @State data) on
/// purpose: positions change on every frame of scrolling, and we don't want
/// that to re-render the whole screen. We only read them when a zoom starts.
final class CardFrames {
    var byID: [Tab.ID: CGRect] = [:]
}

/// Full-screen overview of open tabs, like the iOS app switcher: one big card
/// in the middle with its neighbors peeking in from the sides.
///
/// Opening and leaving are one continuous motion. The page shrinks into its
/// card, and tapping a card makes it grow back to full screen. That motion is
/// drawn by a "hero" picture that travels between the card's frame and the
/// full-screen frame; the live page is only revealed at the very end.
struct TabSwitcher: View {
    let store: BrowserStore
    let onSelect: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onNewTab: () -> Void
    let onDone: () -> Void

    /// Which card is centered in the carousel.
    @State private var centeredID: Tab.ID?
    @State private var cardFrames = CardFrames()

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
        // Start centered on the current tab, with its zoom picture covering
        // the screen so the page doesn't visibly change as we appear.
        _centeredID = State(initialValue: store.selectedTabID)
        _heroID = State(initialValue: store.selectedTabID)
    }

    var body: some View {
        GeometryReader { geometry in
            let screen = CGRect(origin: .zero, size: geometry.size)
            let cardWidth = geometry.size.width * 0.68
            // Same proportions as the screen, so the zoom is a pure scale.
            let cardSize = CGSize(
                width: cardWidth,
                height: cardWidth * geometry.size.height / geometry.size.width
            )

            ZStack {
                Color(.systemGroupedBackground)
                    .opacity(chrome)

                VStack(spacing: 0) {
                    carousel(cardSize: cardSize, screenWidth: geometry.size.width)
                    controls
                }
                .opacity(chrome)
                .allowsHitTesting(heroID == nil)

                hero(screen: screen)
            }
            .coordinateSpace(.named("switcher"))
        }
        .ignoresSafeArea()
        .task { await zoomOut() }
    }

    // MARK: - Pieces

    private func carousel(cardSize: CGSize, screenWidth: CGFloat) -> some View {
        // ScrollViewReader lets us jump straight to the current tab's card
        // before the first frame, with no visible scrolling.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ForEach(store.tabs) { tab in
                        TabCard(
                            tab: tab,
                            size: cardSize,
                            thumbnailHidden: tab.id == heroID,
                            reportFrame: { cardFrames.byID[tab.id] = $0 },
                            onSelect: { zoomIn(to: tab) { onSelect(tab) } },
                            onClose: { closeCard(tab) }
                        )
                        // Cards away from the center are a bit smaller and dimmer.
                        .scrollTransition(axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(1 - abs(phase.value) * 0.1)
                                .opacity(1 - abs(phase.value) * 0.35)
                        }
                        .transition(.opacity)
                    }
                }
                .scrollTargetLayout()
                .frame(maxHeight: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centeredID, anchor: .center)
            // Margins let the first and last cards reach the center too.
            .contentMargins(.horizontal, (screenWidth - cardSize.width) / 2, for: .scrollContent)
            // Vertical swipes (to close) can travel beyond the scroll view's box.
            .scrollClipDisabled()
            .onAppear {
                proxy.scrollTo(store.selectedTabID, anchor: .center)
            }
        }
    }

    /// Mirrors the browser's bottom bar so it feels like the same place.
    private var controls: some View {
        HStack {
            Text(store.tabs.count == 1 ? "1 Tab" : "\(store.tabs.count) Tabs")
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

    /// The traveling picture that does the zoom.
    @ViewBuilder
    private func hero(screen: CGRect) -> some View {
        if let heroID, let tab = store.tabs.first(where: { $0.id == heroID }) {
            let cardFrame = cardFrames.byID[heroID] ?? screen
            let rect = heroExpanded ? screen : cardFrame

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

    // MARK: - Motion

    /// Opening: the full-screen page shrinks down into its card.
    private func zoomOut() async {
        // Let the carousel lay out once so we know where the card is.
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

    private func closeCard(_ tab: Tab) {
        let index = store.tabs.firstIndex { $0.id == tab.id } ?? 0
        onClose(tab)
        // Center the neighbor that took the closed card's place.
        if !store.tabs.isEmpty {
            centeredID = store.tabs[min(index, store.tabs.count - 1)].id
        }
    }
}
