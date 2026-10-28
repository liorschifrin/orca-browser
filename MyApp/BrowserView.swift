import SwiftUI

/// The one and only screen. The page fills the whole display, the bottom
/// bar floats on top of it, and the search overlay floats on top of both.
struct BrowserView: View {
    @State private var store = BrowserStore()
    @State private var barHeight: CGFloat = 0
    // Start with search open: launching the app means "I want to go somewhere".
    @State private var isSearching = true

    var body: some View {
        ZStack {
            page
                // The keyboard must not push the page or bar around.
                .ignoresSafeArea(.keyboard)

            if isSearching {
                SearchOverlay(
                    onSubmit: { input in
                        store.open(input)
                        closeSearch()
                    },
                    onDismiss: closeSearch
                )
                .transition(.opacity)
            }
        }
    }

    /// Page + error/start states + bottom bar, layered back to front.
    private var page: some View {
        ZStack(alignment: .bottom) {
            if let tab = store.selectedTab {
                WebViewHost(webView: tab.webView, bottomInset: barHeight)
                    // Use the full screen, including under the status bar
                    // and home indicator.
                    .ignoresSafeArea()

                // Stop these above the bar so its buttons stay usable.
                if tab.isBlank {
                    StartView()
                        .padding(.bottom, barHeight)
                } else if let error = tab.loadError {
                    ErrorView(error: error, retry: tab.reload)
                        .padding(.bottom, barHeight)
                }

                BottomBar(tab: tab, onNewTab: openSearch)
                    // Report the bar's height so the page can make room.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
        }
    }

    private func openSearch() {
        withAnimation(.easeOut(duration: 0.2)) { isSearching = true }
    }

    private func closeSearch() {
        withAnimation(.easeOut(duration: 0.2)) { isSearching = false }
    }
}

#Preview {
    BrowserView()
}
