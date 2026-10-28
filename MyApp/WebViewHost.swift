import SwiftUI
import WebKit

/// Bridges a UIKit view (WKWebView) into SwiftUI.
///
/// SwiftUI can't show a UIKit view directly. `UIViewRepresentable` is the
/// adapter: SwiftUI asks it for a UIView once, then asks it to update that
/// view whenever our SwiftUI state changes.
///
/// Every tab has its own host, and all of them stay in the view tree. Only
/// the active tab is visible. Because no web view is ever removed and re-added,
/// scroll position and page state can't be lost when switching tabs.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    /// Height of the floating bar covering the bottom of the page.
    let bottomInset: CGFloat
    let isActive: Bool

    func makeUIView(context: Context) -> WKWebView {
        // We don't create a web view here; the Tab already owns one.
        // We just hand that same instance to SwiftUI.
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Hidden views take no touches and cost almost nothing to render.
        uiView.isHidden = !isActive

        // The page extends *under* the bar, so we add scrollable space at the
        // bottom equal to the bar's height. Otherwise the last lines of every
        // page would be stuck behind it. (UIKit adds the home-indicator area
        // on top of this automatically.)
        let scrollView = uiView.scrollView
        scrollView.contentInset.bottom = bottomInset
        scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
    }
}
