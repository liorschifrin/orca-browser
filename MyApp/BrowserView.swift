import SwiftUI

/// The one and only screen. The page fills the whole display, and the bottom
/// bar floats on top of it.
struct BrowserView: View {
    @State private var store = BrowserStore()
    @State private var barHeight: CGFloat = 0

    var body: some View {
        // ZStack layers its children back-to-front: page, error, then bar.
        ZStack(alignment: .bottom) {
            if let tab = store.selectedTab {
                WebViewHost(webView: tab.webView, bottomInset: barHeight)
                    // Use the full screen, including under the status bar
                    // and home indicator.
                    .ignoresSafeArea()

                if let error = tab.loadError {
                    ErrorView(error: error, retry: tab.reload)
                        // Stop above the bar so its buttons stay usable.
                        .padding(.bottom, barHeight)
                }

                BottomBar(tab: tab)
                    // Report the bar's height so the page can make room.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
        }
    }
}

#Preview {
    BrowserView()
}
