import SwiftUI

/// The one and only screen. The page fills the whole display, the bottom
/// bar floats on top of it, and the tab switcher and search overlay float
/// on top of both.
struct BrowserView: View {
    @State private var store = BrowserStore()
    @State private var barHeight: CGFloat = 0
    // Start with search open: launching the app means "I want to go somewhere".
    @State private var isSearching = true
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
    @Environment(\.scenePhase) private var scenePhase

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
                onSubmit: { input in
                    closeSearch()
                    Task {
                        await store.open(input)
                        closeSwitcher()
                    }
                },
                onDismiss: closeSearch
            )
        }
        // Save when leaving the app: iOS may close it without further notice.
        .onChange(of: scenePhase) {
            if scenePhase != .active { store.save() }
        }
        // Every so often, unload tabs that have sat unused for a while.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                store.enforceMemoryPolicy()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            store.unloadBackgroundTabs()
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            RefreshRateBadge()
                .padding(.leading, 12)
        }
        #endif
    }

    /// Every tab's web view, then error/start states. (The bars sit above.)
    private var page: some View {
        ZStack(alignment: .bottom) {
            // All tabs stay mounted; only the selected one is visible.
            ForEach(store.tabs.filter(\.isLoaded)) { tab in
                WebViewHost(
                    webView: tab.webView!,
                    bottomInset: barHeight,
                    isActive: tab.id == store.selectedTabID
                )
                // Use the full screen, including under the status bar
                // and home indicator.
                .ignoresSafeArea()
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
                        .ignoresSafeArea()
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
        ZStack(alignment: .bottom) {
            if let tab = store.selectedTab {
                BottomBar(
                    tab: tab,
                    tabCount: store.tabs.count,
                    onNewTab: openSearch,
                    onShowTabs: openSwitcher
                )
                // Report the bar's height so the page can make room.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                .opacity(1 - barMix)
                .allowsHitTesting(!isSwitching || isExitingSwitcher)
            }

            if isSwitching {
                SwitcherBar(
                    onDone: { doneTrigger += 1 },
                    onNewTab: openSearch,
                    onSettings: {}
                )
                .opacity(barMix)
                .allowsHitTesting(barMix > 0.5)
            }
        }
        // A ZStack is only as big as its contents, and its parent centers it.
        // Without this, the bar sits mid-screen whenever the switcher bar
        // (which happens to fill the screen) isn't there to stretch it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Actions

    private func openSearch() {
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
            // Refresh the current page's picture first, so its card is current.
            // (Skipped when the picture is already current, which is the
            // usual case: it's refreshed shortly after every scroll or load.)
            if let tab = store.selectedTab, tab.needsSnapshot {
                await tab.captureSnapshot()
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
        var replacedWithBlank = false
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
            replacedWithBlank = store.close(tab)
        }
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
