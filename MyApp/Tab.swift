import SwiftUI
import WebKit

/// One browser tab. It owns its own WKWebView for its entire life.
///
/// Keeping the web view alive (instead of recreating it) is what makes tab
/// switching "free": scroll position, form input and history all live inside
/// the web view, so we never have to save or restore them ourselves.
@Observable
final class Tab: Identifiable {
    let id = UUID()
    let webView: WKWebView

    init(url: URL? = nil) {
        let configuration = WKWebViewConfiguration()
        // Play videos inline (in the page) instead of forcing fullscreen.
        configuration.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        // Swiping from the left edge goes back, like Safari.
        webView.allowsBackForwardNavigationGestures = true

        if let url {
            webView.load(URLRequest(url: url))
        }
    }
}
