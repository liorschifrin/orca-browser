import SwiftUI
import WebKit

/// One browser tab.
///
/// A tab is a *record* (address, title, picture of the page) that may or may
/// not have a live WKWebView attached. While a web view is attached it keeps
/// scroll position, form input and history, so switching to the tab is
/// instant. To save memory the store unloads tabs you haven't used lately:
/// the web view is thrown away, but the record stays, along with a
/// "interaction state" blob (back/forward list and scroll position) so that
/// reloading the tab later puts you back where you were.
///
/// The web view is the source of truth for what the page is doing, but SwiftUI
/// can't watch a WKWebView directly. So the Tab *mirrors* the interesting
/// bits (title, progress, ...) into its own properties. Views read those
/// properties and redraw automatically thanks to @Observable.
@Observable
final class Tab: NSObject, Identifiable, WKNavigationDelegate {
    let id: UUID
    /// nil while the tab is unloaded.
    private(set) var webView: WKWebView?
    var isLoaded: Bool { webView != nil }

    // Mirrored from the web view.
    private(set) var url: URL?
    private(set) var title: String?
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false

    /// True until something has been loaded: a brand-new, empty tab.
    private(set) var isBlank = true

    /// Higher = used more recently. Set by the store; the switcher sorts by it.
    var recency = 0

    /// A picture of the page, shown on this tab's card in the switcher.
    private(set) var snapshot: UIImage? {
        didSet { snapshotRevision += 1 }
    }

    /// The site's icon, shown above its card in the switcher. nil until found
    /// (or if the site's icon is a format iOS can't decode, e.g. SVG).
    private(set) var favicon: UIImage? {
        didSet { faviconRevision += 1 }
    }
    @ObservationIgnored private var faviconURL: URL?

    /// Set when a navigation fails; cleared when the next page starts showing.
    private(set) var loadError: LoadError?

    /// True from the moment a web view is re-created for an unloaded tab until
    /// its page shows up. The browser covers the gap with the card's picture.
    private(set) var isRestoring = false

    struct LoadError {
        let message: String
        let failedURL: URL?
    }

    /// Back/forward list and scroll position, kept while the web view is gone.
    @ObservationIgnored private var savedInteractionState: Data?
    /// Last time the user was looking at this tab; drives idle unloading.
    @ObservationIgnored var lastViewed = Date.now
    /// Bumped whenever the picture changes, so saving can skip unchanged ones.
    @ObservationIgnored private(set) var snapshotRevision = 0
    @ObservationIgnored private(set) var faviconRevision = 0
    /// True when the page has changed since the picture was taken.
    @ObservationIgnored private var snapshotIsStale = true
    @ObservationIgnored private var scrollSnapshotTask: Task<Void, Never>?
    /// Told when something worth saving to disk has changed.
    @ObservationIgnored var onChange: (() -> Void)?

    /// KVO (key-value observing) subscriptions. They stop when released.
    /// Not part of the observable state, so views shouldn't track them.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// A new tab with a live web view, loading `url` if given.
    init(url: URL? = nil) {
        id = UUID()
        super.init()

        _ = makeWebView()
        if let url {
            load(url)
        }
    }

    /// A tab brought back from disk. It has no web view until `activate()`.
    init(restoring saved: SavedTab, snapshot: UIImage?, favicon: UIImage?, interactionState: Data?) {
        id = saved.id
        super.init()

        url = saved.url
        title = saved.title
        recency = saved.recency
        isBlank = false
        self.snapshot = snapshot
        self.favicon = favicon
        savedInteractionState = interactionState
        snapshotIsStale = false
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Play videos inline (in the page) instead of forcing fullscreen.
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.addUserScript(
            ShortsFilter.userScript(enabled: AppSettings.shared.hideShorts)
        )

        let view = WKWebView(frame: .zero, configuration: configuration)
        // Swiping from the left edge goes back, like Safari.
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self

        // Whenever any of these web view properties change, re-copy them all.
        observations = [
            view.observe(\.estimatedProgress) { [weak self] view, _ in self?.sync(from: view) },
            view.observe(\.isLoading) { [weak self] view, _ in self?.sync(from: view) },
            view.observe(\.canGoBack) { [weak self] view, _ in self?.sync(from: view) },
            view.observe(\.url) { [weak self] view, _ in self?.sync(from: view) },
            view.observe(\.title) { [weak self] view, _ in self?.sync(from: view) },
            // Scrolling makes the picture out of date; refresh it once the
            // finger has been off for a moment, so opening the switcher
            // doesn't have to wait for a new picture.
            view.scrollView.observe(\.contentOffset) { [weak self] _, _ in self?.pageScrolled() },
        ]
        webView = view
        return view
    }

    // MARK: - Loading and unloading

    /// Makes sure the tab has a web view, re-creating one (and returning to
    /// where you were) if it was unloaded.
    func activate() {
        guard webView == nil else { return }
        let view = makeWebView()
        isRestoring = true

        if let savedInteractionState {
            view.interactionState = savedInteractionState
        }
        // No usable saved state (or it didn't take): just load the address.
        if view.backForwardList.currentItem == nil, let url {
            view.load(URLRequest(url: url))
        }
    }

    /// Throws the web view away to free memory, keeping everything needed to
    /// bring the page back. Blank tabs have nothing worth saving, so they stay.
    func unload() {
        guard let view = webView, !isBlank else { return }

        savedInteractionState = view.interactionState as? Data
        url = view.url ?? url
        title = view.title ?? title
        detach(view)
        webView = nil
        isLoading = false
        progress = 0
        isRestoring = false
    }

    /// The state to write to disk: current if loaded, else what we kept.
    var interactionStateForSaving: Data? {
        (webView?.interactionState as? Data) ?? savedInteractionState
    }

    /// "apple.com" for the bar and cards; falls back to the page title.
    var displayName: String {
        if let host = (url ?? loadError?.failedURL)?.host() {
            return host.replacing("www.", with: "", maxReplacements: 1)
        }
        if let title, !title.isEmpty { return title }
        return "New Tab"
    }

    /// True while the tab is showing a YouTube page.
    var isYouTube: Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
    }

    private func sync(from view: WKWebView) {
        // A re-created web view has no address until its page starts arriving.
        if let current = view.url { url = current }
        if view.title != nil || !isRestoring { title = view.title }
        progress = view.estimatedProgress
        if view.isLoading && !isLoading { snapshotIsStale = true }
        // Half loaded means something is painted: drop the stand-in picture.
        if isRestoring && view.estimatedProgress >= 0.5 {
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                isRestoring = false
            }
        }
        isLoading = view.isLoading
        canGoBack = view.canGoBack
    }

    private func pageScrolled() {
        snapshotIsStale = true
        scrollSnapshotTask?.cancel()
        scrollSnapshotTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let view = webView, !view.isHidden else { return }
            await captureSnapshot()
        }
    }

    // MARK: - Actions

    func load(_ url: URL) {
        isBlank = false
        loadError = nil
        activate()
        webView?.load(URLRequest(url: url))
    }

    func goBack() {
        webView?.goBack()
    }

    func reload() {
        // After a failed first load there's no page to reload, so retry the
        // URL that failed instead.
        if let failedURL = loadError?.failedURL {
            load(failedURL)
        } else {
            webView?.reload()
        }
    }

    func stopLoading() {
        webView?.stopLoading()
    }

    /// True if the card's picture should be refreshed before showing it.
    var needsSnapshot: Bool {
        !isBlank && isLoaded && (snapshot == nil || snapshotIsStale)
    }

    /// Takes a small picture of what the web view is showing right now.
    /// Call this *before* the web view is hidden: a hidden view may render blank.
    func captureSnapshot() async {
        guard !isBlank, let view = webView else { return }
        let configuration = WKSnapshotConfiguration()
        // Cards are small, so a modest width keeps memory low.
        configuration.snapshotWidth = 400
        if let image = try? await view.takeSnapshot(configuration: configuration) {
            snapshot = image
            snapshotIsStale = false
            onChange?()
        }
    }

    /// Finds the page's icon and downloads it. The page itself says where the
    /// icon is (a <link> tag); if it doesn't, the conventional /favicon.ico is
    /// tried. Only the site's own server is contacted.
    private func loadFavicon() async {
        guard let pageURL = webView?.url, pageURL.scheme?.hasPrefix("http") == true else { return }

        let script = """
        (function () {
          var selectors = ['link[rel="apple-touch-icon"]', 'link[rel~="icon"]'];
          for (var i = 0; i < selectors.length; i++) {
            var link = document.querySelector(selectors[i]);
            if (link && link.href) { return link.href; }
          }
          return null;
        })()
        """
        let declared = (try? await webView?.evaluateJavaScript(script)) as? String
        let iconURL = declared.flatMap { URL(string: $0) }
            ?? URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
        guard let iconURL, iconURL != faviconURL else { return }

        guard let (data, _) = try? await URLSession.shared.data(from: iconURL),
              let image = UIImage(data: data) else { return }
        faviconURL = iconURL
        favicon = image
    }

    /// Called when the tab is closed, so the page stops loading and playing.
    func teardown() {
        scrollSnapshotTask?.cancel()
        if let view = webView { detach(view) }
        webView = nil
    }

    private func detach(_ view: WKWebView) {
        scrollSnapshotTask?.cancel()
        observations = []
        view.stopLoading()
        view.navigationDelegate = nil
    }

    // MARK: - WKNavigationDelegate

    /// A page finished loading: refresh the card picture. (The leaving-the-tab
    /// snapshot can be taken mid-load, which would leave a half-empty card.)
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isRestoring = false
        Task { await loadFavicon() }
        Task {
            // Give the page a moment to paint its final layout.
            try? await Task.sleep(for: .milliseconds(400))
            if !webView.isHidden || snapshot == nil {
                await captureSnapshot()
            }
            onChange?()
        }
    }

    /// Turns youtube.com/shorts/ID addresses into the normal watch page while
    /// Shorts are hidden.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if AppSettings.shared.hideShorts,
           action.targetFrame?.isMainFrame ?? true,
           let url = action.request.url,
           let watchURL = ShortsFilter.watchURL(forShorts: url) {
            decisionHandler(.cancel)
            load(watchURL)
            return
        }
        decisionHandler(.allow)
    }

    /// Applies the Shorts setting to a page that is already open.
    func setHidesShorts(_ enabled: Bool) {
        webView?.evaluateJavaScript(ShortsFilter.setScript(enabled: enabled))
    }

    /// Called once the first bytes of a new page arrive, i.e. the old page is
    /// about to be replaced. A good moment to drop any old error.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loadError = nil
        snapshotIsStale = true

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
        isRestoring = false

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
