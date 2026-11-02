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
final class Tab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id: UUID
    /// nil while the tab is unloaded.
    private(set) var webView: WKWebView?
    var isLoaded: Bool { webView != nil }

    // Mirrored from the web view.
    private(set) var url: URL?
    /// The last search or submitted address, retained when following links.
    var searchText = ""
    private(set) var title: String?
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    /// True until something has been loaded: a brand-new, empty tab.
    private(set) var isBlank = true

    /// Higher = used more recently. Set by the store; the switcher sorts by it.
    var recency = 0

    /// A picture of the page, shown on its card in the switcher and as a
    /// stand-in while the tab reloads. Held in memory only while the tab is
    /// live or about to show it; otherwise it's on disk, and cards use a
    /// small thumbnail of it (see `CardThumbnails`).
    private(set) var snapshot: UIImage?
    /// True when there is a picture, in memory or on disk.
    private(set) var hasSnapshot = false
    /// Bumped whenever a new picture is taken, so saving can skip unchanged
    /// ones and cards know to fetch a new thumbnail.
    private(set) var snapshotRevision = 0
    /// Where the picture and history are filed: under this tab's own id, or,
    /// for a held link's page, under the tab it belongs to.
    @ObservationIgnored var fileOwner: (id: UUID, isPeek: Bool)

    /// The site's icon, shown above its card in the switcher. nil until found
    /// (or if the site's icon is a format iOS can't decode, e.g. SVG).
    private(set) var favicon: UIImage? {
        didSet { faviconRevision += 1 }
    }
    @ObservationIgnored private var faviconURL: URL?

    /// Requests blocked on the current page, by kind. Start again at each page.
    private(set) var adsBlocked = 0
    private(set) var trackersBlocked = 0

    /// True when the loaded page appears to be in a language the user doesn't
    /// read (see `Translation`). Cleared when the next page starts arriving.
    private(set) var isForeignLanguage = false

    /// Set when a navigation fails; cleared when the next page starts showing.
    private(set) var loadError: LoadError?

    /// True from the moment a web view is re-created for an unloaded tab until
    /// its page shows up. The browser covers the gap with the card's picture.
    private(set) var isRestoring = false
    @ObservationIgnored private var restoreNavigationFinished = false
    @ObservationIgnored private var restoreFinishTask: Task<Void, Never>?

    /// The held link's page belongs to this tab, even while another tab is selected.
    struct Peek {
        let url: URL
        let tab: Tab
    }
    private(set) var peek: Peek?
    /// A returning peek should appear immediately rather than replay its entrance.
    private(set) var peekWasPresented = false

    struct LoadError {
        let message: String
        let failedURL: URL?
    }

    /// Back/forward list and scroll position, kept while the web view is gone.
    @ObservationIgnored private var savedInteractionState: Data?
    /// Last time the user was looking at this tab; drives idle unloading.
    @ObservationIgnored var lastViewed = Date.now
    /// Bumped whenever the icon changes, so saving can skip unchanged ones.
    @ObservationIgnored private(set) var faviconRevision = 0
    /// True when the page has changed since the picture was taken.
    @ObservationIgnored private var snapshotIsStale = true
    @ObservationIgnored private var scrollSnapshotTask: Task<Void, Never>?
    /// Counts pictures being taken, so a slow one can't replace a newer one.
    @ObservationIgnored private var snapshotsStarted = 0
    /// Told when something worth saving to disk has changed.
    @ObservationIgnored var onChange: (() -> Void)?

    /// KVO (key-value observing) subscriptions. They stop when released.
    /// Not part of the observable state, so views shouldn't track them.
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// A new tab with a live web view, loading `url` if given.
    init(url: URL? = nil, input: String? = nil) {
        id = UUID()
        fileOwner = (id, false)
        super.init()

        _ = makeWebView()
        if let url {
            load(url, input: input)
        }
    }

    /// A tab brought back from disk. It has no web view until `activate()`,
    /// and its picture and history stay on disk until then.
    init(restoring saved: SavedTab, owner: (id: UUID, isPeek: Bool)? = nil, hasSnapshot: Bool, favicon: UIImage?, peekHasSnapshot: Bool = false) {
        id = saved.id
        fileOwner = owner ?? (saved.id, false)
        super.init()

        url = saved.url
        searchText = saved.searchText ?? Destination.searchQuery(from: saved.url)
            ?? saved.url?.absoluteString ?? ""
        title = saved.title
        recency = saved.recency
        isBlank = false
        self.hasSnapshot = hasSnapshot
        self.favicon = favicon
        snapshotIsStale = false
        if let savedPeek = saved.peek {
            let peekTab = Tab(restoring: SavedTab(
                id: UUID(), url: savedPeek.currentURL ?? savedPeek.url,
                title: savedPeek.title, recency: 0, peek: nil
            ), owner: (saved.id, true), hasSnapshot: peekHasSnapshot, favicon: nil)
            peekTab.onChange = { [weak self] in self?.onChange?() }
            peek = Peek(url: savedPeek.url, tab: peekTab)
            peekWasPresented = true
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Play videos inline (in the page) instead of forcing fullscreen.
        configuration.allowsInlineMediaPlayback = true
        ContentBlocker.shared.install(on: configuration.userContentController)
        configuration.userContentController.addUserScript(LinkPress.userScript)
        configuration.userContentController.addUserScript(
            ShortsFilter.userScript(enabled: AppSettings.shared.hideShorts)
        )
        configuration.userContentController.addUserScript(BackgroundPlayback.userScript)

        let view = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
        // Lets Safari's Web Inspector on a Mac attach to pages in debug builds.
        view.isInspectable = true
        #endif
        // Swiping from the left edge goes back, like Safari.
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsLinkPreview = false

        // Whenever any of these web view properties change, re-copy them all.
        observations = [
            view.observe(\.estimatedProgress) { [weak self] view, _ in self?.sync(from: view) },
            view.observe(\.isLoading) { [weak self] view, _ in self?.sync(from: view) },
            view.observe(\.canGoBack) { [weak self] view, _ in self?.sync(from: view) },
            view.observe(\.canGoForward) { [weak self] view, _ in self?.sync(from: view) },
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
        // The picture covers the page until it's back, and the history
        // puts it back where it was. Both wait on disk until now.
        if snapshot == nil, hasSnapshot {
            snapshot = TabPersistence.loadSnapshot(for: self)
        }
        if savedInteractionState == nil {
            savedInteractionState = TabPersistence.loadInteractionState(for: self)
        }
        // Restoring a page may not report its address before its requests start.
        if let url { ContentBlocker.shared.willNavigate(view.configuration.userContentController, to: url) }
        restoreNavigationFinished = false
        restoreFinishTask?.cancel()
        restoreFinishTask = nil

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
        restoreNavigationFinished = false
        restoreFinishTask?.cancel()
        restoreFinishTask = nil
        peek?.tab.unload()
    }

    /// Lets go of the in-memory picture. Only for pictures already saved;
    /// cards and `activate()` read it back from disk.
    func releaseSnapshot() {
        if snapshot != nil { snapshot = nil }
    }

    /// Remove the saved picture only after the restored navigation has finished
    /// and its web view is actually showing behind that picture.
    func finishRestoringIfVisible() {
        guard isRestoring, restoreNavigationFinished, restoreFinishTask == nil,
              let view = webView, !view.isHidden else { return }
        restoreFinishTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            defer { restoreFinishTask = nil }
            guard !Task.isCancelled, self.webView === view,
                  !view.isHidden, !view.isLoading else { return }
            isRestoring = false
        }
    }

    /// The state to write to disk: current if loaded, else what we kept.
    var interactionStateForSaving: Data? {
        (webView?.interactionState as? Data) ?? savedInteractionState
    }

    func openPeek(_ url: URL) {
        guard peek == nil else { return }
        let peekTab = Tab()
        peekTab.fileOwner = (id, true)
        peekTab.onChange = { [weak self] in self?.onChange?() }
        peek = Peek(url: url, tab: peekTab)
        peekWasPresented = false
        onChange?()
    }

    func markPeekPresented() { peekWasPresented = true }

    func dismissPeek() {
        peek?.tab.teardown()
        peek = nil
        onChange?()
    }

    /// Transfers the loaded peek page into the tab list without reloading it.
    func takePeek() -> Tab? {
        guard let peek else { return nil }
        // Its files move with it: bring the picture into memory before the
        // ones filed under this tab are cleared away.
        if peek.tab.snapshot == nil, peek.tab.hasSnapshot {
            peek.tab.snapshot = TabPersistence.loadSnapshot(for: peek.tab)
        }
        peek.tab.fileOwner = (peek.tab.id, false)
        self.peek = nil
        peek.tab.onChange = nil
        onChange?()
        return peek.tab
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
    var isYouTube: Bool { url.map(Self.isYouTube) ?? false }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
    }

    private func sync(from view: WKWebView) {
        // A re-created web view has no address until its page starts arriving.
        if let current = view.url, current != url {
            url = current
            if let query = Destination.searchQuery(from: current) {
                searchText = query
            }
            onChange?()
        }
        // Assign only what changed: every assignment redraws the views that
        // read it, and this runs many times per page load.
        if view.title != title, view.title != nil || !isRestoring { title = view.title }
        if view.estimatedProgress != progress { progress = view.estimatedProgress }
        if view.isLoading && !isLoading { snapshotIsStale = true }
        if view.isLoading != isLoading { isLoading = view.isLoading }
        if view.canGoBack != canGoBack { canGoBack = view.canGoBack }
        if view.canGoForward != canGoForward { canGoForward = view.canGoForward }
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

    func load(_ url: URL, input: String? = nil) {
        if let input {
            searchText = Destination.searchQuery(from: url) ?? input
        } else if let query = Destination.searchQuery(from: url) {
            searchText = query
        }
        isBlank = false
        loadError = nil
        activate()
        webView?.load(URLRequest(url: url))
        onChange?()
    }

    /// The tab's whole history, oldest first, and where the current page is in it.
    var history: (items: [WKBackForwardListItem], current: Int) {
        guard let list = webView?.backForwardList else { return ([], 0) }
        var items = list.backList
        let current = items.count
        if let item = list.currentItem { items.append(item) }
        items += list.forwardList
        return (items, current)
    }

    func go(to item: WKBackForwardListItem) {
        webView?.go(to: item)
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
        !isBlank && isLoaded && (!hasSnapshot || snapshotIsStale)
    }

    /// Takes a picture of what the web view is showing right now.
    /// Call this *before* the web view is hidden: a hidden view may render blank.
    func captureSnapshot() async {
        guard !isBlank, let view = webView else { return }
        snapshotsStarted += 1
        let number = snapshotsStarted
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 400
        guard let image = try? await view.takeSnapshot(configuration: configuration) else { return }
        // WebKit renders at the screen's scale (3x on most iPhones). 2x is
        // plenty for cards and the brief stand-in, at under half the memory.
        let picture = await Task.detached(priority: .utility) {
            Self.atTwiceScale(image)
        }.value
        // A newer picture was started meanwhile; it wins.
        guard number == snapshotsStarted else { return }
        snapshot = picture
        hasSnapshot = true
        snapshotRevision += 1
        snapshotIsStale = false
        onChange?()
    }

    nonisolated private static func atTwiceScale(_ image: UIImage) -> UIImage {
        guard image.scale > 2 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
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

    /// Decides whether the page is in a language the user doesn't read.
    private func detectLanguage() async {
        guard let view = webView, view.url?.scheme?.hasPrefix("http") == true else { return }
        let script = """
        (function () {
          return {
            lang: document.documentElement.lang || '',
            text: (document.body ? document.body.innerText : '').slice(0, 2000)
          };
        })()
        """
        guard let result = (try? await view.evaluateJavaScript(script)) as? [String: Any] else { return }
        let declared = result["lang"] as? String ?? ""
        let text = result["text"] as? String ?? ""
        // Language recognition is CPU work; keep it off the main thread.
        let foreign = await Task.detached(priority: .utility) {
            Translation.isForeign(declared: declared, text: text)
        }.value
        // The user may have moved on while the script ran.
        if view === webView { isForeignLanguage = foreign }
    }

    /// Called when the tab is closed, so the page stops loading and playing.
    func teardown() {
        scrollSnapshotTask?.cancel()
        restoreFinishTask?.cancel()
        peek?.tab.teardown()
        peek = nil
        if let view = webView { detach(view) }
        webView = nil
    }

    private func detach(_ view: WKWebView) {
        scrollSnapshotTask?.cancel()
        observations = []
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }

    // MARK: - WKNavigationDelegate

    /// A page finished loading: refresh the card picture. (The leaving-the-tab
    /// snapshot can be taken mid-load, which would leave a half-empty card.)
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isRestoring {
            restoreNavigationFinished = true
            finishRestoringIfVisible()
        }
        Task { await loadFavicon() }
        Task { await detectLanguage() }
        Task {
            // Give the page a moment to paint its final layout.
            try? await Task.sleep(for: .milliseconds(400))
            if !webView.isHidden || !hasSnapshot {
                await captureSnapshot()
            }
            onChange?()
        }
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
            load(watchURL)
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
        guard (action.value(forKey: "blockedLoad") as? Bool) == true else { return }
        switch ContentBlocker.shared.category(ofList: identifier) {
        case .ads: adsBlocked += 1
        case .trackers: trackersBlocked += 1
        case nil: break
        }
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

    /// Applies the Shorts setting to a page that is already open.
    func setHidesShorts(_ enabled: Bool) {
        webView?.evaluateJavaScript(ShortsFilter.setScript(enabled: enabled))
    }

    /// Called once the first bytes of a new page arrive, i.e. the old page is
    /// about to be replaced. A good moment to drop any old error.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loadError = nil
        snapshotIsStale = true
        adsBlocked = 0
        trackersBlocked = 0
        isForeignLanguage = false
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

        restoreFinishTask?.cancel()
        restoreFinishTask = nil
        isRestoring = false
        loadError = LoadError(
            message: nsError.localizedDescription,
            failedURL: nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        )
    }
}
