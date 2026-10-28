import SwiftUI
import WebKit

/// One browser tab. It owns its own WKWebView for its entire life.
///
/// Keeping the web view alive (instead of recreating it) is what makes tab
/// switching "free": scroll position, form input and history all live inside
/// the web view, so we never have to save or restore them ourselves.
///
/// The web view is the source of truth for what the page is doing, but SwiftUI
/// can't watch a WKWebView directly. So the Tab *mirrors* the interesting
/// bits (title, progress, ...) into its own properties. Views read those
/// properties and redraw automatically thanks to @Observable.
@Observable
final class Tab: NSObject, Identifiable, WKNavigationDelegate {
    let id = UUID()
    let webView: WKWebView

    // Mirrored from the web view.
    private(set) var url: URL?
    private(set) var title: String?
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false

    /// Set when a navigation fails; cleared when the next page starts showing.
    private(set) var loadError: LoadError?

    struct LoadError {
        let message: String
        let failedURL: URL?
    }

    /// KVO (key-value observing) subscriptions. They stop when released.
    /// Not part of the observable state, so views shouldn't track them.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(url: URL? = nil) {
        let configuration = WKWebViewConfiguration()
        // Play videos inline (in the page) instead of forcing fullscreen.
        configuration.allowsInlineMediaPlayback = true

        webView = WKWebView(frame: .zero, configuration: configuration)
        // Swiping from the left edge goes back, like Safari.
        webView.allowsBackForwardNavigationGestures = true

        super.init()

        webView.navigationDelegate = self

        // Whenever any of these web view properties change, re-copy them all.
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.syncFromWebView() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.syncFromWebView() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.syncFromWebView() },
            webView.observe(\.url) { [weak self] _, _ in self?.syncFromWebView() },
            webView.observe(\.title) { [weak self] _, _ in self?.syncFromWebView() },
        ]

        if let url {
            load(url)
        }
    }

    private func syncFromWebView() {
        url = webView.url
        title = webView.title
        progress = webView.estimatedProgress
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
    }

    // MARK: - Actions

    func load(_ url: URL) {
        loadError = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        webView.goBack()
    }

    func reload() {
        // After a failed first load there's no page to reload, so retry the
        // URL that failed instead.
        if let failedURL = loadError?.failedURL {
            load(failedURL)
        } else {
            webView.reload()
        }
    }

    func stopLoading() {
        webView.stopLoading()
    }

    // MARK: - WKNavigationDelegate

    /// Called once the first bytes of a new page arrive, i.e. the old page is
    /// about to be replaced. A good moment to drop any old error.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loadError = nil
    }

    /// Failure before anything arrived (offline, bad host, ...).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    /// Failure after the page had started arriving.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError

        // Not real failures: the user (or a link tap) cancelled a load, or the
        // page turned into a download. Showing an error would be noise.
        let isCancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let isInterrupted = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
        guard !isCancelled, !isInterrupted else { return }

        loadError = LoadError(
            message: nsError.localizedDescription,
            failedURL: nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        )
    }
}
