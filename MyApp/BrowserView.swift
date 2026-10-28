import SwiftUI

/// The one and only screen. The page fills the whole display; later the
/// bottom bar and overlays will float on top of it.
struct BrowserView: View {
    @State private var store = BrowserStore()

    var body: some View {
        ZStack {
            // Show only the selected tab's web view.
            if let tab = store.selectedTab {
                WebViewHost(webView: tab.webView)
                    // Use the full screen, including under the status bar
                    // and home indicator.
                    .ignoresSafeArea()
            }
        }
    }
}

#Preview {
    BrowserView()
}
