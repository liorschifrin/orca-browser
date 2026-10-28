import SwiftUI
import WebKit

/// Bridges a UIKit view (WKWebView) into SwiftUI.
///
/// SwiftUI can't show a UIKit view directly. `UIViewRepresentable` is the
/// adapter: SwiftUI asks it for a UIView once, then asks it to update that
/// view whenever our SwiftUI state changes.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        // We don't create a web view here; the Tab already owns one.
        // We just hand that same instance to SwiftUI.
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Nothing to push into the web view yet.
    }
}
