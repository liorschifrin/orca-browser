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

    var body: some View {
        ZStack {
            page
                // The keyboard must not push the page or bar around.
                .ignoresSafeArea(.keyboard)

            if isSwitching {
                TabSwitcher(
                    store: store,
                    onSelect: { tab in
                        store.select(tab)
                        closeSwitcher()
                    },
                    onClose: closeTab,
                    onNewTab: openSearch,
                    onDone: closeSwitcher
                )
                .ignoresSafeArea(.keyboard)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

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
    }

    /// Every tab's web view, then error/start states, then the bottom bar.
    private var page: some View {
        ZStack(alignment: .bottom) {
            // All tabs stay mounted; only the selected one is visible.
            ForEach(store.tabs) { tab in
                WebViewHost(
                    webView: tab.webView,
                    bottomInset: barHeight,
                    isActive: tab.id == store.selectedTabID
                )
                // Use the full screen, including under the status bar
                // and home indicator.
                .ignoresSafeArea()
            }

            if let tab = store.selectedTab {
                // Stop these above the bar so its buttons stay usable.
                if tab.isBlank {
                    StartView()
                        .padding(.bottom, barHeight)
                } else if let error = tab.loadError {
                    ErrorView(error: error, retry: tab.reload)
                        .padding(.bottom, barHeight)
                }

                BottomBar(
                    tab: tab,
                    tabCount: store.tabs.count,
                    onNewTab: openSearch,
                    onShowTabs: openSwitcher
                )
                // Report the bar's height so the page can make room.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
        }
    }

    // MARK: - Actions

    private func openSearch() {
        withAnimation(.easeOut(duration: 0.2)) { isSearching = true }
    }

    private func closeSearch() {
        withAnimation(.easeOut(duration: 0.2)) { isSearching = false }
    }

    private func openSwitcher() {
        Task {
            // Refresh the current page's picture first, so its card is current.
            await store.selectedTab?.captureSnapshot()
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { isSwitching = true }
        }
    }

    private func closeSwitcher() {
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) { isSwitching = false }
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
