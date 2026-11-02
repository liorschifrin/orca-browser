import WebKit

/// The live page behind a tab: creates and configures its web view, copies
/// what the page is doing into the `Tab`, and answers WebKit's questions
/// (may this navigation go ahead, what about a new window).
///
/// The `Tab` is the record and outlives this: a tab that's unloaded to save
/// memory drops its controller and web view, and gets new ones when it's
/// shown again.
final class TabWebController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private weak var tab: Tab?

    /// KVO (key-value observing) subscriptions. They stop when released.
    private var observations: [NSKeyValueObservation] = []

    init(tab: Tab) {
        self.tab = tab
        let configuration = WKWebViewConfiguration()
        // Play videos inline (in the page) instead of forcing fullscreen.
        configuration.allowsInlineMediaPlayback = true
        ContentBlocker.shared.install(on: configuration.userContentController)
        configuration.userContentController.addUserScript(LinkPress.userScript)
        configuration.userContentController.addUserScript(
            ShortsFilter.userScript(enabled: AppSettings.shared.hideShorts)
        )
        configuration.userContentController.addUserScript(BackgroundPlayback.userScript)

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        #if DEBUG
        // Lets Safari's Web Inspector on a Mac attach to pages in debug builds.
        webView.isInspectable = true
        #endif
        // Swiping from the left edge goes back, like Safari.
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false

        // Whenever any of these web view properties change, re-copy them all.
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] view, _ in self?.tab?.mirror(view) },
            webView.observe(\.isLoading) { [weak self] view, _ in self?.tab?.mirror(view) },
            webView.observe(\.canGoBack) { [weak self] view, _ in self?.tab?.mirror(view) },
            webView.observe(\.canGoForward) { [weak self] view, _ in self?.tab?.mirror(view) },
            webView.observe(\.url) { [weak self] view, _ in self?.tab?.mirror(view) },
            webView.observe(\.title) { [weak self] view, _ in self?.tab?.mirror(view) },
            // Scrolling makes the tab's picture out of date.
            webView.scrollView.observe(\.contentOffset) { [weak self] _, _ in self?.tab?.pageScrolled() },
        ]
    }

    /// Stops the page and cuts it loose from the tab, which is letting go of it.
    func detach() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.pageDidFinish()
    }

    /// Turns youtube.com/shorts/ID addresses into the normal watch page while
    /// Shorts are hidden.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if AppSettings.shared.hideShorts,
           isMainFrame,
           let url = action.request.url,
           let watchURL = ShortsFilter.watchURL(forShorts: url) {
            decisionHandler(.cancel)
            tab?.load(watchURL)
            return
        }
        // Before the page's requests go out, give it the right blocking lists:
        // a site can have ad or tracker blocking switched off.
        if isMainFrame, let url = action.request.url {
            ContentBlocker.shared.willNavigate(webView.configuration.userContentController, to: url)
        }
        decisionHandler(.allow)
    }

    /// WebKit tells its delegate whenever a blocking list acts on a request.
    /// This callback isn't part of the public API, which has no way to count
    /// what was blocked, so this is the only place that depends on it. If WebKit
    /// ever drops it, blocking keeps working and the counts stay at zero.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard (action.value(forKey: "blockedLoad") as? Bool) == true,
              let category = ContentBlocker.shared.category(ofList: identifier) else { return }
        tab?.countBlocked(category)
    }

    /// Called once the first bytes of a new page arrive, i.e. the old page is
    /// about to be replaced.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.pageDidCommit()
    }

    /// Failure before anything arrived (offline, bad host, ...).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab?.pageDidFail(error)
    }

    /// Failure after the page had started arriving.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab?.pageDidFail(error)
    }

    // MARK: - WKUIDelegate

    /// Links with target="_blank" and window.open() ask for a new window.
    /// Without this, WebKit silently ignores them; open them in this tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil {
            webView.load(action.request)
        }
        return nil
    }
}
