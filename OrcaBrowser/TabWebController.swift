import WebKit

/// The live page behind a tab: creates and configures its web view, copies
/// what the page is doing into the `Tab`, and answers WebKit's questions
/// (may this navigation go ahead, what about a new window).
///
/// The `Tab` is the record and outlives this: a tab that's unloaded to save
/// memory drops its controller and web view, and gets new ones when it's
/// shown again.
final class TabWebController: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private weak var tab: Tab?

    /// KVO (key-value observing) subscriptions. They stop when released.
    private var observations: [NSKeyValueObservation] = []

    init(tab: Tab) {
        self.tab = tab
        let configuration = WKWebViewConfiguration()
        if let store = tab.privateDataStore { configuration.websiteDataStore = store }
        // Play videos inline (in the page) instead of forcing fullscreen.
        configuration.allowsInlineMediaPlayback = true
        ContentBlocker.shared.install(on: configuration.userContentController, privateRules: tab.privateRules)
        ConsentReject.install(on: configuration.userContentController) { [weak tab] message in
            ContentBlocker.shared.rejectsConsent(on: message.webView?.url, privateRules: tab?.privateRules)
        }
        configuration.userContentController.addUserScript(LinkPress.userScript)
        configuration.userContentController.addUserScript(
            ShortsFilter.userScript(enabled: AppSettings.shared.hideShorts)
        )
        configuration.userContentController.addUserScript(
            ShortsFilter.redirectUserScript(enabled: AppSettings.shared.opensShortsAsVideos)
        )
        configuration.userContentController.addUserScript(
            YouTubeSpeedBumps.userScript(AppSettings.shared.speedBumpsInPage)
        )
        configuration.userContentController.addUserScript(BackgroundPlayback.userScript)
        configuration.userContentController.addUserScript(PlaybackControl.userScript)
        configuration.userContentController.addUserScript(VideoFullscreen.userScript)
        configuration.userContentController.addUserScript(YouTubeHeader.userScript(
            hidesOpenApp: AppSettings.shared.hidesOpenApp, showsTools: AppSettings.shared.showsHeaderTools
        ))
        configuration.userContentController.addUserScript(
            RedditPrompt.userScript(enabled: AppSettings.shared.blockRedditPrompt)
        )

        webView = PageWebView(frame: .zero, configuration: configuration)
        super.init()
        // The page reports picture in picture changes in its own script world.
        // A weak bridge, so the web view doesn't keep this controller alive.
        for name in Self.messageNames {
            configuration.userContentController.add(
                WeakMessageHandler(self), contentWorld: .page, name: name
            )
        }

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
        VideoFullscreen.forget(webView)
        for name in Self.messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: name, contentWorld: .page
            )
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    // MARK: - WKScriptMessageHandler

    /// What the page's scripts report to the app.
    private static let messageNames = [
        BackgroundPlayback.pictureInPictureMessageName,
        PlaybackControl.messageName,
        YouTubeHeader.chaptersMessageName,
        VideoFullscreen.messageName,
    ]

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case BackgroundPlayback.pictureInPictureMessageName:
            guard let body = message.body as? [String: Any], let active = body["active"] as? Bool else { return }
            tab?.pictureInPictureChanged(active: active)
        case PlaybackControl.messageName:
            guard let state = PlaybackControl.State(message: message.body) else { return }
            tab?.playback = state
        case YouTubeHeader.chaptersMessageName:
            tab?.isShowingChapters = true
        case VideoFullscreen.messageName:
            guard let body = message.body as? [String: Any], let active = body["active"] as? Bool else { return }
            VideoFullscreen.changed(webView, active: active)
        default:
            break
        }
    }

    private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
        private weak var target: WKScriptMessageHandler?
        init(_ target: WKScriptMessageHandler) { self.target = target }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab?.pageDidFinish()
    }

    /// Turns youtube.com/shorts/ID addresses into the normal watch page when
    /// Shorts are set to open as videos. This covers full page loads; taps
    /// inside YouTube are caught by the page script.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isMainFrame = action.targetFrame?.isMainFrame ?? true
        if AppSettings.shared.opensShortsAsVideos,
           isMainFrame,
           let url = action.request.url,
           let watchURL = ShortsFilter.watchURL(forShorts: url) {
            decisionHandler(.cancel)
            tab?.load(watchURL)
            return
        }
        // Which frame asked. WebKit leaves it out for loads the app starts.
        let isFromPage = (action.sourceFrame as WKFrameInfo?)?.isMainFrame ?? true
        // A tap in a frame (an ad) takes back an earlier tap in the page.
        if Self.isUserTap(action) { lastLinkTap = isFromPage ? .now : nil }
        // Reloading or going back isn't a tap, even right after one.
        if action.navigationType == .reload || action.navigationType == .backForward { lastLinkTap = nil }
        // Phone, email, App Store and other app links go to their app. Only
        // the page itself: an ad in a frame mustn't be able to switch apps
        // without asking, even by loading the link into the whole page.
        if isMainFrame, let url = action.request.url, let appURL = AppLink.appURL(for: url) {
            decisionHandler(.cancel)
            openInApp(appURL, isFromPage: isFromPage)
            return
        }
        // Google Search and its home page open in English. Only plain page loads:
        // a form that sends data keeps its request as it is.
        if AppSettings.shared.googleInEnglish,
           isMainFrame,
           action.request.httpMethod?.uppercased() ?? "GET" == "GET",
           let url = action.request.url,
           let english = GoogleLanguage.englishURL(for: url) {
            decisionHandler(.cancel)
            tab?.load(english)
            return
        }
        // Before the page's requests go out, give it the right blocking lists:
        // a site can have ad or tracker blocking switched off.
        if isMainFrame, let url = action.request.url {
            ContentBlocker.shared.willNavigate(webView.configuration.userContentController, to: url)
        }
        decisionHandler(Self.allowWithoutApps)
    }

    /// `.allow` lets WebKit hand addresses that an installed app claims
    /// (universal links like apps.apple.com) to that app, even when a page
    /// reloads or redirects there on its own. This value, which WebKit leaves
    /// out of its public headers, loads them in the tab instead, so only
    /// `AppLink` and `openInApp` decide when to leave the browser. Firefox for
    /// iOS uses the same value.
    private static let allowWithoutApps = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2)!

    /// WebKit tells its delegate whenever a blocking list acts on a request.
    /// This callback isn't part of the public API, which has no way to count
    /// what was blocked, so this is the only place that depends on it. If WebKit
    /// ever drops it, blocking keeps working and the counts stay at zero.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard (action.value(forKey: "blockedLoad") as? Bool) == true,
              let category = ContentBlocker.shared.category(ofList: identifier) else { return }
        tab?.countBlocked(category, url: url)
    }

    /// Called once the first bytes of a new page arrive, i.e. the old page is
    /// about to be replaced.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        tab?.pageDidCommit()
        // The tap led here; what this page does next is up to the page.
        lastLinkTap = nil
        // The YouTube countdown settings may have changed since this web view
        // was made, and its user script still has the old ones.
        webView.evaluateJavaScript(
            YouTubeSpeedBumps.setScript(AppSettings.shared.speedBumpsInPage), in: nil, in: YouTubeSpeedBumps.world
        )
        // Hidden banners often leave the page unable to scroll.
        if ContentBlocker.shared.hidesBanners(on: webView.url, privateRules: tab?.privateRules) {
            webView.evaluateJavaScript(CookieBanners.unlockScrollScript)
        }
    }

    /// Failure before anything arrived (offline, bad host, ...).
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        tab?.pageDidFail(error, beforeCommit: true)
    }

    /// Failure after the page had started arriving.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab?.pageDidFail(error, beforeCommit: false)
    }

    /// The web content process quit, usually because iOS reclaimed its memory.
    /// The page is gone and the view would stay blank.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        tab?.pageProcessDidTerminate()
    }

    // MARK: - App links

    /// When a link was last tapped. A tap leads to an app link through a
    /// redirect or the page's own script, so it counts for a few seconds,
    /// until the next page arrives.
    private var lastLinkTap: Date?
    private static let tapLifetime: TimeInterval = 5

    /// Whether a real touch started this navigation, including a page script
    /// that runs because of the touch. `.linkActivated` alone also covers a
    /// script clicking a link on its own. WebKit keeps this flag out of its
    /// public API; without it nothing counts as a tap, and app links ask first.
    private static func isUserTap(_ action: WKNavigationAction) -> Bool {
        let key = "_isUserInitiated"
        guard action.responds(to: NSSelectorFromString(key)) else { return false }
        return action.value(forKey: key) as? Bool == true
    }

    /// Opens `url` in its app at once after a tap; otherwise the page is
    /// trying to switch apps on its own, so ask first, like Safari.
    private func openInApp(_ url: URL, isFromPage: Bool) {
        // A tab that's off screen, or the app in the background, can't be
        // what the user just tapped, so it can't leave nor ask.
        guard let tab, !webView.isHidden, webView.window != nil, InteractionBudget.shared.isForeground else { return }
        if isFromPage, let lastLinkTap, Date.now.timeIntervalSince(lastLinkTap) < Self.tapLifetime {
            self.lastLinkTap = nil
            UIApplication.shared.open(url)
            return
        }
        // The browser asks this, not the page, so it shows even where page
        // dialogs are switched off. Name the page that's showing, not the
        // address being loaded.
        let site = ContentBlocker.site(for: webView.backForwardList.currentItem?.url ?? webView.url)
        tab.present(PageDialog(kind: .openApp, message: "Open this link in another app?", site: site) { response in
            if case .ok = response { UIApplication.shared.open(url) }
        })
    }

    // MARK: - WKUIDelegate

    /// Hands a page's dialog to the tab to show, or answers "Cancel" at once
    /// if it can't be shown: dialogs are switched off (everywhere or for this
    /// site), or the page isn't on screen. WebKit pauses the page until
    /// `respond` is called, and requires it be called exactly once.
    private func present(_ kind: PageDialog.Kind, _ message: String, respond: @escaping (PageDialog.Response) -> Void) {
        let site = ContentBlocker.site(for: webView.url)
        guard let tab, !webView.isHidden, webView.window != nil,
              PageDialogPermissions.shared.mayShow(on: site, privateRules: tab.privateRules) else {
            respond(.cancel)
            return
        }
        tab.present(PageDialog(kind: kind, message: message, site: site, respond: respond))
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        present(.alert, message) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        present(.confirm, message) { response in
            if case .ok = response { completionHandler(true) } else { completionHandler(false) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        present(.prompt(defaultText: defaultText ?? ""), prompt) { response in
            if case .ok(let text) = response { completionHandler(text ?? "") } else { completionHandler(nil) }
        }
    }

    /// Links with target="_blank" and window.open() ask for a new window.
    /// Without this, WebKit silently ignores them; open them in this tab.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil {
            // Pages can't open windows on their own (WebKit's default), so
            // this always comes from a tap, even when the page's script asks.
            // A tap in a frame (an ad) doesn't count, and takes back an
            // earlier tap in the page.
            let isFromPage = (action.sourceFrame as WKFrameInfo?)?.isMainFrame ?? true
            lastLinkTap = isFromPage ? .now : nil
            // Loading the request here would lose which frame asked.
            if let url = action.request.url, let appURL = AppLink.appURL(for: url) {
                openInApp(appURL, isFromPage: isFromPage)
                return nil
            }
            webView.load(action.request)
        }
        return nil
    }
}
