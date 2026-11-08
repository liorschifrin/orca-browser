import OSLog
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
/// properties and redraw automatically thanks to @Observable. The web view
/// itself, and WebKit's callbacks, are handled by a `TabWebController`.
@Observable
final class Tab: Identifiable {
    let id: UUID
    let isIncognito: Bool
    /// Set for tabs of the incognito window, which share one session. Other
    /// incognito tabs each have a session of their own.
    @ObservationIgnored let session: PrivateSession?
    var isInIncognitoWindow: Bool { session != nil }
    /// Retained across memory-pressure unloading; never backed by disk.
    @ObservationIgnored private(set) var privateDataStore: WKWebsiteDataStore?
    /// Site choices (blocking, dialogs) made in incognito, shared by the
    /// incognito tabs that are not in the window (the window has its own).
    /// In memory only; nil for normal tabs, which save theirs.
    @ObservationIgnored let privateRules: PrivateSiteRules?
    @ObservationIgnored private var isClosed = false
    /// nil while the tab is unloaded.
    private(set) var webView: WKWebView?
    @ObservationIgnored private var controller: TabWebController?
    var isLoaded: Bool { webView != nil }

    // Mirrored from the web view.
    private(set) var url: URL? {
        didSet {
            // Incognito site choices last while some tab is still on the site.
            // (A nil address is only teardown, which forgets the tab itself.)
            guard isIncognito, let url, url != oldValue else { return }
            privateRules?.tab(id, isOn: ContentBlocker.site(for: url))
        }
    }
    /// The last search or submitted address, retained when following links.
    var searchText = ""
    var searchProviderID: String?
    private(set) var title: String?
    private(set) var progress: Double = 0
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false

    @ObservationIgnored private var lastRecordedURL: URL?

    /// True until something has been loaded: a brand-new, empty tab.
    private(set) var isBlank = true

    /// Higher = used more recently. Set by the store; the switcher sorts by it.
    var recency = 0
    var lastOpenedAt = Date.now

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
    @ObservationIgnored private var faviconTask: Task<Void, Never>?

    /// Requests blocked on the current page, by kind. Start again at each page.
    private(set) var adsBlocked = 0
    private(set) var trackersBlocked = 0
    private(set) var bannersBlocked = 0
    /// What was already counted on this page: a page whose script retries a
    /// blocked request in a loop is still one blocked request.
    @ObservationIgnored private var countedBlockedURLs = Set<URL>()

    /// True when the loaded page appears to be in a language the user doesn't
    /// read (see `Translation`). Cleared when the next page starts arriving.
    private(set) var isForeignLanguage = false

    /// True when the loaded page looks like an article (see `ArchivePage`).
    /// Cleared when the next page starts arriving.
    private(set) var isArticle = false

    /// A dialog the page is waiting on, shown by the browser as an alert.
    private(set) var dialog: PageDialog?

    /// Set when a navigation fails; cleared when the next page starts showing.
    private(set) var loadError: LoadError?

    /// True from the moment a web view is re-created for an unloaded tab until
    /// its page shows up. The browser covers the gap with the card's picture.
    private(set) var isRestoring = false
    @ObservationIgnored private var restoreNavigationFinished = false
    @ObservationIgnored private var isReadingInteractionState = false
    @ObservationIgnored private var restoreLoadTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var isCapturingSnapshot = false
    @ObservationIgnored private var restoreFinishTask: Task<Void, Never>?
    @ObservationIgnored private var restoreTimeoutTask: Task<Void, Never>?

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

    /// Empty tabs are lightweight records; create WebKit only for navigation.
    /// A `session` makes the tab one of the incognito window's.
    init(url: URL? = nil, input: String? = nil, providerID: String? = nil, isIncognito: Bool = false, session: PrivateSession? = nil) {
        id = UUID()
        let isIncognito = isIncognito || session != nil
        self.isIncognito = isIncognito
        self.session = session
        privateDataStore = session?.dataStore ?? (isIncognito ? .nonPersistent() : nil)
        privateRules = session?.rules ?? (isIncognito ? .shared : nil)
        fileOwner = (id, false)

        if let url {
            load(url, input: input, providerID: providerID)
        }
    }

    /// A tab brought back from disk. It has no web view until `activate()`,
    /// and its picture and history stay on disk until then.
    init(restoring saved: SavedTab, owner: (id: UUID, isPeek: Bool)? = nil, hasSnapshot: Bool, favicon: UIImage?, peekHasSnapshot: Bool = false) {
        id = saved.id
        isIncognito = false
        session = nil
        privateRules = nil
        fileOwner = owner ?? (saved.id, false)

        url = saved.url
        searchProviderID = saved.searchProviderID
        searchText = saved.searchText ?? Destination.searchQuery(from: saved.url)
            ?? saved.url?.absoluteString ?? ""
        title = saved.title
        recency = saved.recency
        lastOpenedAt = saved.lastOpenedAt ?? .now
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
        let controller = TabWebController(tab: self)
        self.controller = controller
        webView = controller.webView
        return controller.webView
    }

    // MARK: - Loading and unloading

    /// Makes sure the tab has a web view, re-creating one (and returning to
    /// where you were) if it was unloaded.
    func activate(restoreState: Bool = true) {
        guard !isClosed, webView == nil, !isBlank else { return }
        let view = makeWebView()
        guard restoreState, !isBlank else { return }
        isRestoring = true
        startRestoreTimeout(for: view)
        if let url { ContentBlocker.shared.willNavigate(view.configuration.userContentController, to: url) }
        restoreNavigationFinished = false
        restoreFinishTask?.cancel()
        restoreFinishTask = nil
        // Disk I/O cannot block the transition to this tab. Screenshots are
        // optional; restore history first and use a placeholder meanwhile.
        isReadingInteractionState = true
        restoreLoadTask = Task { [weak self, weak view] in
            guard let self, let view else { return }
            var state = savedInteractionState
            if state == nil { state = await TabPersistence.readInteractionState(for: self) }
            guard !Task.isCancelled, webView === view else { return }
            savedInteractionState = state
            isReadingInteractionState = false
            if let state { view.interactionState = state }
            if view.backForwardList.currentItem == nil, let url {
                view.load(URLRequest(url: url))
            }
        }
    }

    /// Throws the web view away to free memory, keeping everything needed to
    /// bring the page back. Blank tabs have nothing worth saving, so they stay.
    func unload() {
        guard let view = webView, !isBlank else { return }

        if !isReadingInteractionState { savedInteractionState = view.interactionState as? Data }
        url = view.url ?? url
        title = view.title ?? title
        detachWebView()
        isLoading = false
        progress = 0
        endRestoring()
        restoreNavigationFinished = false
        restoreFinishTask?.cancel()
        restoreFinishTask = nil
        peek?.tab.unload()
    }

    /// Lets go of the in-memory picture. Only for pictures already saved;
    /// cards and `activate()` read it back from disk.
    func releaseSnapshot() {
        if !isIncognito, snapshot != nil { snapshot = nil }
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
            endRestoring()
        }
    }

    /// Removes the stand-in picture. Every way a restore can end comes through
    /// here, so the timeout below is always cancelled with it.
    private func endRestoring() {
        isRestoring = false
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = nil
    }

    /// The picture sits on top of the live page, so a restore that never
    /// reports "finished" (a still-loading page, a cancelled or dropped
    /// navigation) would leave a tab that looks frozen. Give up on the picture
    /// after a while, and if nothing was ever loaded, load the address.
    private func startRestoreTimeout(for view: WKWebView) {
        restoreTimeoutTask?.cancel()
        restoreTimeoutTask = Task { [weak self, weak view] in
            try? await Task.sleep(for: .seconds(Self.restoreTimeout))
            guard let self, !Task.isCancelled, let view, webView === view, isRestoring else { return }
            endRestoring()
            loadIfNothingShowing(in: view)
        }
    }

    private static let restoreTimeout = 6.0

    /// A restored web view that has no page and isn't loading one gets the
    /// tab's address.
    private func loadIfNothingShowing(in view: WKWebView) {
        guard !isReadingInteractionState, !view.isLoading, view.url == nil,
              let url = url ?? loadError?.failedURL else { return }
        view.load(URLRequest(url: url))
    }

    /// The state to write to disk: current if loaded, else what we kept.
    var interactionStateForSaving: Data? {
        guard !isIncognito else { return nil }
        if isReadingInteractionState { return savedInteractionState }
        return (webView?.interactionState as? Data) ?? savedInteractionState
    }

    func openPeek(_ url: URL) {
        guard !isClosed, peek == nil else { return }
        let peekTab = Tab(isIncognito: isIncognito, session: session)
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

    /// Copies what the web view is doing into the tab. Called by the
    /// controller whenever one of those properties changes.
    func mirror(_ view: WKWebView) {
        // A re-created web view has no address until its page starts arriving.
        var urlChanged = false
        if let current = view.url, current != url {
            url = current
            urlChanged = true
            refreshSearchState(for: current)
            onChange?()
        }
        let previousTitle = title
        // Assign only what changed: every assignment redraws the views that
        // read it, and this runs many times per page load.
        if view.title != title, view.title != nil || !isRestoring { title = view.title }
        if view.estimatedProgress != progress { progress = view.estimatedProgress }
        recordHistory(urlChanged: urlChanged, titleChanged: title != previousTitle)
        if view.isLoading && !isLoading { snapshotIsStale = true }
        if view.isLoading != isLoading { isLoading = view.isLoading }
        // The check after "finished" gives up while the page is still loading;
        // try again once it stops.
        if isRestoring, !view.isLoading { finishRestoringIfVisible() }
        if view.canGoBack != canGoBack { canGoBack = view.canGoBack }
        if view.canGoForward != canGoForward { canGoForward = view.canGoForward }
    }

    /// Tells the history about a new address or a new title for this one.
    /// A new address arrives with the *previous* page's title still showing,
    /// so it's recorded without one; the real title follows.
    private func recordHistory(urlChanged: Bool, titleChanged: Bool) {
        guard !isIncognito, !isClosed, !isRestoring, loadError == nil, let url else { return }
        if urlChanged || lastRecordedURL != url {
            lastRecordedURL = url
            HistoryStore.deferVisit(url, title: nil, isNew: true)
        } else if titleChanged, let title {
            HistoryStore.deferVisit(url, title: title, isNew: false)
        }
    }

    /// Scrolling makes the picture out of date; refresh it once the finger
    /// has been off for a moment, so opening the switcher doesn't have to
    /// wait for a new picture.
    func pageScrolled() {
        InteractionBudget.shared.interacted()
        snapshotIsStale = true
        scrollSnapshotTask?.cancel()
        scheduleSnapshot()
    }

    private func scheduleSnapshot() {
        scrollSnapshotTask?.cancel()
        scrollSnapshotTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(600))
                try await InteractionBudget.shared.waitForIdle()
                guard let self, let view = webView, !view.isHidden,
                      !view.isLoading, needsSnapshot else { return }
                await captureSnapshot()
            } catch { }
        }
    }

    /// Google result navigation replaces a stale search, but retains a chip
    /// when the current URL still matches that provider's search parameters.
    func refreshSearchState(for url: URL) {
        guard let query = Destination.searchQuery(from: url) else { return }
        if let providerID = searchProviderID {
            let provider = AppSettings.shared.searchProviders.first { $0.id == providerID }
            let expected = provider?.url(for: query)
            let expectedParts = expected.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            var actualParts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let decodedQuery = actualParts?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
            actualParts?.percentEncodedQuery = decodedQuery
            let expectedItems = expectedParts?.queryItems ?? []
            let actualItems = actualParts?.queryItems ?? []
            /// Treats Google Images parameter aliases as the same search mode.
            func mode(_ items: [URLQueryItem]) -> String {
                let udm = items.first { $0.name == "udm" }?.value
                let tbm = items.first { $0.name == "tbm" }?.value
                // Google can redirect its Images template to the older parameter.
                if udm == "2" || tbm == "isch" { return "images" }
                return "\(udm ?? "")/\(tbm ?? "")"
            }
            let matches = Destination.searchQuery(from: expected) == query
                && expectedItems.filter { $0.name != "udm" && $0.name != "tbm" }
                    .allSatisfy { actualItems.contains($0) }
                && mode(expectedItems) == mode(actualItems)
            if !matches { searchProviderID = nil }
        }
        searchText = query
    }

    // MARK: - Actions

    /// Starts navigation, retaining submitted search state or reconciling a later Google query.
    func load(_ url: URL, input: String? = nil, providerID: String? = nil) {
        guard !isClosed else { return }
        if let input {
            searchProviderID = providerID
            searchText = providerID == nil ? (Destination.searchQuery(from: url) ?? input) : input
        } else {
            refreshSearchState(for: url)
        }
        isBlank = false
        loadError = nil
        InteractionBudget.shared.interacted()
        restoreLoadTask?.cancel()
        isReadingInteractionState = false
        activate(restoreState: false)
        endRestoring()
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
        } else if let view = webView {
            // Reloading is the user's way out of a restore that went wrong.
            if isRestoring { endRestoring() }
            if view.url == nil, let url { view.load(URLRequest(url: url)) } else { view.reload() }
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
        guard !isBlank, !isCapturingSnapshot, let view = webView,
              !view.isHidden, !view.isLoading else { return }
        isCapturingSnapshot = true
        defer { isCapturingSnapshot = false }
        let interval = PerformanceTrace.signposter.beginInterval("Page snapshot")
        defer { PerformanceTrace.signposter.endInterval("Page snapshot", interval) }
        snapshotsStarted += 1
        let number = snapshotsStarted
        guard let picture = await PageSnapshotter.capture(view) else { return }
        // A newer picture was started meanwhile; it wins.
        guard !isClosed, !Task.isCancelled, number == snapshotsStarted, webView === view else { return }
        snapshot = picture
        hasSnapshot = true
        snapshotRevision += 1
        snapshotIsStale = false
        onChange?()
    }

    /// Finds the page's icon and downloads it, unless it's the one we have.
    private func loadFavicon() async {
        guard let view = webView, let pageURL = view.url,
              let iconURL = await PageMetadata.iconURL(in: view), iconURL != faviconURL,
              let image = await PageMetadata.icon(at: iconURL, isIncognito: isIncognito),
              !isClosed, view === webView else { return }
        faviconURL = iconURL
        favicon = image
        if !isIncognito { HistoryStore.shared.saveIcon(image, for: pageURL) }
    }

    /// Decides whether the page is in a language the user doesn't read.
    private func detectLanguage() async {
        guard let view = webView, let foreign = await PageMetadata.isForeignLanguage(view) else { return }
        // The user may have moved on while the script ran.
        if view === webView { isForeignLanguage = foreign }
    }

    /// Decides whether the page is an article, for the archive button.
    private func detectArticle() async {
        guard let view = webView, let article = await PageMetadata.isArticle(view) else { return }
        if view === webView { isArticle = article }
    }

    /// Called when the tab is closed, so the page stops loading and playing.
    func teardown() {
        isClosed = true
        snapshotsStarted += 1
        onChange = nil
        faviconTask?.cancel()
        faviconTask = nil
        scrollSnapshotTask?.cancel()
        restoreFinishTask?.cancel()
        restoreTimeoutTask?.cancel()
        peek?.tab.teardown()
        peek = nil
        detachWebView()
        if isIncognito {
            snapshot = nil
            hasSnapshot = false
            favicon = nil
            faviconURL = nil
            savedInteractionState = nil
            url = nil
            title = nil
            searchText = ""
            loadError = nil
            // The window's tabs share their store; the window wipes it.
            if session == nil, let store = privateDataStore {
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            }
            privateDataStore = nil
            privateRules?.forget(tab: id)
        }
    }

    private func detachWebView() {
        answerDialog(.cancel)
        restoreLoadTask?.cancel()
        metadataTask?.cancel()
        snapshotsStarted += 1
        scrollSnapshotTask?.cancel()
        controller?.detach()
        controller = nil
        webView = nil
    }

    // MARK: - Page events (from the controller)

    /// A page finished loading: refresh the card picture. (The leaving-the-tab
    /// snapshot can be taken mid-load, which would leave a half-empty card.)
    /// Set by the store: switch to this tab. Called when you return to its
    /// video from the picture in picture window.
    @ObservationIgnored var onPictureInPictureReturn: (() -> Void)?
    @ObservationIgnored private(set) var isInPictureInPicture = false

    /// The page's video opened or closed picture in picture. Leaving it while
    /// the app is on screen and the video still plays is the "return to app"
    /// button; the close button pauses the video instead, and happens with the
    /// app in the background. The check waits a moment because the app takes
    /// a moment to come forward after that button.
    func pictureInPictureChanged(active: Bool) {
        let wasActive = isInPictureInPicture
        isInPictureInPicture = active
        guard wasActive, !active else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, UIApplication.shared.applicationState != .background,
                  let playing = try? await webView?.evaluateJavaScript(
                      "[...document.querySelectorAll('video')].some(v => !v.paused)"
                  ) as? Bool, playing
            else { return }
            onPictureInPictureReturn?()
        }
    }

    /// What the page's video is doing, reported by its script. The playback
    /// bar shows while a watch page video is available.
    var playback = PlaybackControl.State()
    /// The chapters list is open (the top bar's chapters button was tapped).
    var isShowingChapters = false

    /// Where the video is now, in seconds.
    func currentTime() async -> Double? {
        let result = try? await webView?.callAsyncJavaScript(
            "return window.__orcaPlayback?.time()", arguments: [:], in: nil, contentWorld: .page
        )
        return result as? Double
    }

    /// Applies the YouTube top bar settings to a page that is already open.
    func applyYouTubeSettings(_ settings: AppSettings) {
        webView?.evaluateJavaScript(YouTubeHeader.settingsScript(
            hidesOpenApp: settings.hidesOpenApp, showsTools: settings.showsHeaderTools
        ))
    }

    func send(_ command: PlaybackControl.Command) {
        webView?.callAsyncJavaScript("return " + command.script, arguments: [:], in: nil, in: .page) { _ in }
    }

    @ObservationIgnored private var pictureInPictureRestoredAt = Date.distantPast

    /// You tapped "return to app" in the picture in picture window. The page
    /// is told so it can keep the video playing.
    func pictureInPictureRestoreTapped() {
        pictureInPictureRestoredAt = .now
        webView?.evaluateJavaScript("window.__orcaPictureInPictureRestoring && window.__orcaPictureInPictureRestoring()")
    }

    /// Puts a video that's in picture in picture back in the page. Not just
    /// after "return to app", which is already doing that.
    func exitPictureInPicture() {
        guard isInPictureInPicture, Date.now.timeIntervalSince(pictureInPictureRestoredAt) > 3 else { return }
        webView?.callAsyncJavaScript("return window.__orcaExitPictureInPicture?.()", arguments: [:], in: nil, in: .page) { _ in }
    }

    /// Pauses a video on the page, unless it's in picture in picture. Used when
    /// you switch away from the tab.
    func pauseVideos() {
        webView?.evaluateJavaScript("window.__orcaPauseVideos && window.__orcaPauseVideos()")
    }

    func pageDidFinish() {
        if isRestoring {
            restoreNavigationFinished = true
            finishRestoringIfVisible()
        }
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            do {
                try await InteractionBudget.shared.waitForIdle()
                guard let self, webView?.isHidden == false else { return }
                await loadFavicon()
                try Task.checkCancellation()
                try await InteractionBudget.shared.waitForIdle()
                await detectLanguage()
                if AppSettings.shared.showsArchiveButton {
                    try Task.checkCancellation()
                    await detectArticle()
                }
            } catch { }
        }
        snapshotIsStale = true
        scheduleSnapshot()
        onChange?()
    }

    /// The first bytes of a new page arrived, i.e. the old page is about to
    /// be replaced. A good moment to drop any old error.
    func pageDidCommit() {
        playback = PlaybackControl.State()
        snapshotsStarted += 1
        scrollSnapshotTask?.cancel()
        loadError = nil
        snapshotIsStale = true
        adsBlocked = 0
        trackersBlocked = 0
        bannersBlocked = 0
        countedBlockedURLs.removeAll()
        isForeignLanguage = false
        isArticle = false
    }

    /// Shows a dialog the page asked for, unless one is already up, in which
    /// case the new one is answered "Cancel" straight away.
    func present(_ dialog: PageDialog) {
        guard self.dialog == nil else {
            dialog.respond(.cancel)
            return
        }
        self.dialog = dialog
    }

    /// Answers the waiting dialog, if any, and lets the page carry on.
    func answerDialog(_ response: PageDialog.Response) {
        guard let dialog else { return }
        self.dialog = nil
        dialog.respond(response)
    }

    func countBlocked(_ category: ContentBlocker.Category, url: URL) {
        guard countedBlockedURLs.insert(url).inserted else { return }
        switch category {
        case .ads: adsBlocked += 1
        case .trackers: trackersBlocked += 1
        case .cookieBanners: bannersBlocked += 1
        }
    }

    /// Applies the Reddit pop-up setting to a page that is already open.
    func setBlocksRedditPrompt(_ enabled: Bool) {
        webView?.evaluateJavaScript(RedditPrompt.setScript(enabled: enabled))
    }

    /// Applies the Shorts hiding setting to a page that is already open.
    func setHidesShorts(_ enabled: Bool) {
        webView?.evaluateJavaScript(ShortsFilter.setScript(enabled: enabled))
    }

    /// Applies the "open Shorts as videos" setting to a page that is already open.
    func setOpensShortsAsVideos(_ enabled: Bool) {
        webView?.evaluateJavaScript(ShortsFilter.setRedirectScript(enabled: enabled))
    }

    func pageDidFail(_ error: Error) {
        let nsError = error as NSError

        // Not real failures: the user (or a link tap) cancelled a load, or the
        // page turned into a download. Showing an error would be noise.
        let isCancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        let isInterrupted = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
        guard !isCancelled, !isInterrupted else { return }

        restoreFinishTask?.cancel()
        restoreFinishTask = nil
        endRestoring()
        loadError = LoadError(
            message: nsError.localizedDescription,
            failedURL: nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        )
    }
}
