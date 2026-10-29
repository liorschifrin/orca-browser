import SwiftUI

/// The one and only screen. The page fills the whole display, the bottom
/// bar floats on top of it, and the tab switcher and search overlay float
/// on top of both.
struct BrowserView: View {
    @State private var store: BrowserStore
    @State private var previewLink: PreviewLink?

    private struct PreviewLink: Identifiable {
        let id = UUID()
        let url: URL
        let source: Tab
    }

    @State private var barHeight: CGFloat = 0
    // Search starts open only when there's no page to go back to (a blank tab).
    @State private var isSearching: Bool
    // Set when search was opened by tapping the address: the URL to show,
    // and the submitted text then replaces the current page.
    @State private var editingURL: URL?
    @State private var isSwitching = false
    /// A new value for every time the switcher opens, so SwiftUI never reuses
    /// a switcher that was mid-exit (it would still think it was "leaving").
    @State private var switcherID = UUID()
    @State private var isPreparingSwitcher = false
    /// The switcher is animating away (a card was picked).
    @State private var isExitingSwitcher = false
    /// The tabs button was tapped during that exit: open it again afterwards.
    @State private var reopenAfterExit = false
    /// 0 = browser bar, 1 = switcher bar. Driven by the switcher's animation.
    @State private var barMix: Double = 0
    @State private var doneTrigger = 0
    @State private var isShowingSettings = false
    private let settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = BrowserStore()
        _store = State(initialValue: store)
        _isSearching = State(initialValue: store.selectedTab?.isBlank ?? true)
    }

    var body: some View {
        ZStack {
            page
                // The keyboard must not push the page or bar around.
                .ignoresSafeArea(.keyboard)

            if isSwitching {
                TabSwitcher(
                    store: store,
                    barMix: $barMix,
                    doneTrigger: doneTrigger,
                    onSelect: { tab in
                        store.select(tab)
                        closeSwitcher()
                    },
                    onClose: closeTab,
                    onDone: closeSwitcher,
                    onLeaveStart: { isExitingSwitcher = true }
                )
                .ignoresSafeArea(.keyboard)
                .id(switcherID)
                // It animates its own entrance, so appear instantly; on the
                // way out, cross-fade from the card to the live page.
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }

            bars
                // Same rule as the page: the keyboard doesn't push the bar up.
                .ignoresSafeArea(.keyboard)

            // Always in the view tree, just invisible when closed. A text
            // field that already exists can take the keyboard instantly;
            // one that has to be built first adds a noticeable delay.
            SearchOverlay(
                isPresented: isSearching,
                initialText: editingURL?.absoluteString ?? "",
                onSubmit: { input in
                    let replacing = editingURL != nil
                    closeSearch()
                    Task {
                        if replacing, let tab = store.selectedTab,
                           let url = Destination.url(for: input) {
                            tab.load(url)
                        } else {
                            await store.open(input)
                        }
                        closeSwitcher()
                    }
                },
                onDismiss: closeSearch
            )

            if let link = previewLink {
                LinkPreview(
                    url: link.url,
                    onOpenNewTab: { tab in
                        previewLink = nil
                        store.adoptPreview(tab, inBackground: false)
                    },
                    onOpenBackground: { tab in
                        previewLink = nil
                        store.adoptPreview(tab, inBackground: true)
                    },
                    onOpen: { url in
                        previewLink = nil
                        link.source.load(url)
                    },
                    onDismiss: { previewLink = nil }
                )
                .id(link.id)
            }
        }
        // Save when leaving the app: iOS may close it without further notice.
        .onChange(of: scenePhase) {
            if scenePhase == .active { ClipboardCache.shared.refresh() }
            else { store.save() }
        }
        .onChange(of: settings.hideShorts) {
            store.applyShortsSetting(settings.hideShorts)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(settings: settings, onDone: { isShowingSettings = false })
        }
        // Every so often, unload tabs that have sat unused for a while.
        .task {
            ClipboardCache.shared.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                store.enforceMemoryPolicy()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            ClipboardCache.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            store.unloadBackgroundTabs()
        }
    }

    /// Every tab's web view, then error/start states. (The bars sit above.)
    private var page: some View {
        ZStack(alignment: .bottom) {
            // All tabs stay mounted; only the selected one is visible.
            ForEach(store.tabs.filter(\.isLoaded)) { tab in
                WebViewHost(
                    webView: tab.webView!,
                    isActive: tab.id == store.selectedTabID,
                    onPreviewLink: { url in
                        guard previewLink == nil, tab.id == store.selectedTabID else { return }
                        previewLink = PreviewLink(url: url, source: tab)
                    }
                )
                // Sit between the status bar and the floating bar, so nothing
                // on the page (header buttons, the end of an inner scrolling
                // panel like comments) is hidden behind them.
                .padding(.bottom, barHeight)
            }

            if let tab = store.selectedTab {
                // A tab that was unloaded takes a moment to come back; show its
                // card picture meanwhile instead of a white page.
                if tab.isRestoring, let image = tab.snapshot {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                        .padding(.bottom, barHeight)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
                // Stop these above the bar so its buttons stay usable.
                if tab.isBlank {
                    StartView()
                        .padding(.bottom, barHeight)
                } else if let error = tab.loadError {
                    ErrorView(error: error, retry: tab.reload)
                        .padding(.bottom, barHeight)
                }
            }
        }
    }

    /// Both bottom bars, stacked above the page and the switcher, fading
    /// into one another as the switcher opens and closes.
    private var bars: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if let tab = store.selectedTab {
                    BottomBar(
                        tab: tab,
                        tabCount: store.tabs.count,
                        plusButtonWidth: geometry.size.width * 0.19,
                        onNewTab: { openSearch() },
                        onEditAddress: { openSearch(editing: store.selectedTab?.url) },
                        onShowTabs: openSwitcher
                    )
                    // Put the address strip just above the physical bottom edge.
                    .padding(.bottom, -max(0, geometry.safeAreaInsets.bottom - 3))
                    // Report the bar's height so the page can make room.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    .opacity(1 - barMix)
                    .allowsHitTesting(!isSwitching || isExitingSwitcher)
                }

                if isSwitching {
                    SwitcherBar(
                        height: barHeight,
                        plusButtonWidth: geometry.size.width * 0.19,
                        onDone: { doneTrigger += 1 },
                        onNewTab: { openSearch() },
                        onSettings: { isShowingSettings = true }
                    )
                    // `barHeight` was measured after the browser bar's negative
                    // bottom padding, so this lands the button row exactly
                    // where the browser bar's is. No padding of its own.
                    .opacity(barMix)
                    .allowsHitTesting(barMix > 0.5)
                }
            }
            // Anchor both bars to the bottom of the available screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    // MARK: - Actions

    private func openSearch(editing url: URL? = nil) {
        editingURL = url
        withAnimation(.easeOut(duration: 0.2)) { isSearching = true }
    }

    private func closeSearch() {
        withAnimation(.easeOut(duration: 0.2)) { isSearching = false }
    }

    private func openSwitcher() {
        // Tapped while the switcher is flying away: reopen once it's gone.
        if isExitingSwitcher {
            reopenAfterExit = true
            return
        }
        // Ignore taps while one is already on its way (or open).
        guard !isPreparingSwitcher, !isSwitching else { return }
        isPreparingSwitcher = true
        Task {
            // Only wait for a picture when there is none at all. Otherwise the
            // one we have (refreshed after every scroll or load) is shown now,
            // and a newer one swaps in if it's still being taken.
            if let tab = store.selectedTab, tab.needsSnapshot {
                if tab.snapshot == nil {
                    await tab.captureSnapshot()
                } else {
                    Task { await tab.captureSnapshot() }
                }
            }
            switcherID = UUID()
            isSwitching = true
            isPreparingSwitcher = false
        }
    }

    private func closeSwitcher() {
        withAnimation(.easeOut(duration: 0.15)) {
            isSwitching = false
            barMix = 0
        }
        isExitingSwitcher = false
        if reopenAfterExit {
            reopenAfterExit = false
            openSwitcher()
        }
    }

    private func closeTab(_ tab: Tab) {
        // The switcher owns the close/reflow animation for both its local
        // card list and the store; avoid a second, longer nested spring.
        let replacedWithBlank = store.close(tab)
        // Closed the very last tab: go back to the "start fresh" state.
        if replacedWithBlank {
            closeSwitcher()
            openSearch()
        }
    }
}

#Preview {
    BrowserView()
}
