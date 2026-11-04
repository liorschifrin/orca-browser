import ContentBlockerConverter
import Foundation
import OSLog
import PublicSuffixList
import WebKit

/// Blocks ads, trackers and cookie banners in every tab with WebKit's own content blocking.
///
/// WebKit compiles blocking rules once into a compact form and matches every
/// request against it natively, so pages don't run any extra JavaScript and
/// loading stays fast. The slow part is turning AdGuard's filter lists into
/// those rules, so that happens rarely and in the background:
///
/// - The compiled lists are saved by WebKit. At launch they are only looked up
///   (milliseconds), never rebuilt.
/// - The filter lists are re-checked every few days. The server is asked
///   whether a list changed (ETag), and only a changed list is converted again.
/// - Converting and compiling run at low priority, one list at a time, after
///   the first page has had a head start.
///
/// Each filter list becomes its own rule list. That keeps every list well under
/// WebKit's per-list limit and lets a category be switched off without work.
final class ContentBlocker {
    static let shared = ContentBlocker()

    enum Category: CaseIterable {
        case ads, trackers, cookieBanners

        /// Where the sites with this category switched off are saved.
        fileprivate var offSitesKey: String {
            switch self {
            case .ads: "contentBlocker.adsOffSites"
            case .trackers: "contentBlocker.trackersOffSites"
            case .cookieBanners: "contentBlocker.cookieBannersOffSites"
            }
        }
    }

    /// A list of blocking rules: an AdGuard filter in the variant AdGuard
    /// optimizes for Safari, or rules that ship inside the app.
    struct Filter {
        enum Source {
            case adguard
            /// Rules already in WebKit's format. Nothing is downloaded.
            case builtIn(json: String)
        }

        let id: Int
        let category: Category
        let name: String
        var source = Source.adguard

        var identifier: String {
            switch source {
            case .adguard: "orcabrowser.adguard.\(id)"
            // The rules are part of the name, so edited rules compile afresh.
            case .builtIn(let json): "\(Self.builtInPrefix)\(id).\(Self.fingerprint(json))"
            }
        }

        /// nil for built-in rules.
        var url: URL? {
            guard case .adguard = source else { return nil }
            return URL(string: "https://filters.adtidy.org/ios/filters/\(id)_optimized.txt")!
        }

        static let builtInPrefix = "orcabrowser.builtin."

        /// FNV-1a: a short, stable name for some text.
        private static func fingerprint(_ text: String) -> String {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return String(hash, radix: 16)
        }
    }

    static let filters = [
        Filter(id: 2, category: .ads, name: "AdGuard Base"),
        Filter(id: 11, category: .ads, name: "AdGuard Mobile Ads"),
        Filter(id: 3, category: .trackers, name: "AdGuard Tracking Protection"),
        Filter(id: 18, category: .cookieBanners, name: "AdGuard Cookie Notices"),
        // AdGuard hides few banners of the big consent platforms with plain rules.
        Filter(id: 1001, category: .cookieBanners, name: "Consent platforms (built in)",
               source: .builtIn(json: CookieBanners.hideRulesJSON)),
    ]

    /// AdGuard's lists say they expire after five days.
    private static let updateInterval: TimeInterval = 3 * 24 * 60 * 60
    fileprivate static let lastCheckKey = "contentBlocker.lastCheck"

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OrcaBrowser", category: "ContentBlocker")
    private let settings = AppSettings.shared
    private var compiled: [Int: WKContentRuleList] = [:] { didSet { status.setLoaded(Set(compiled.keys)) } }
    /// What the Debug section of Settings shows.
    let status = Status()
    /// Set by `updateNow()`: stop waiting for quiet and go.
    private var isForced = false
    /// What each web view currently has. Weak keys, so closed tabs fall out by themselves.
    private let attachments = NSMapTable<WKUserContentController, Attachment>.weakToStrongObjects()
    private var started = false
    private var isUpdating = false
    private var needsAnotherPass = false

    private init() {
        status.restore(Self.filters)
    }

    // MARK: - Status

    /// Where each list stands, for the Debug section of Settings.
    @Observable
    final class Status {
        enum Phase: Equatable { case idle, waiting, downloading, converting, compiling, failed(String) }

        struct Entry: Identifiable {
            let id: Int
            let name: String
            var phase = Phase.idle
            var isLoaded = false
            var rules: Int?
            var bytes: Int?
            var updated: Date?
        }

        private(set) var entries: [Entry] = []
        private(set) var isUpdating = false
        private(set) var lastCheck: Date?

        private static func key(_ id: Int) -> String { "contentBlocker.stat.\(id)" }

        func restore(_ filters: [Filter]) {
            entries = filters.map { filter in
                var entry = Entry(id: filter.id, name: filter.name)
                let saved = UserDefaults.standard.dictionary(forKey: Self.key(filter.id))
                entry.rules = saved?["rules"] as? Int
                entry.bytes = saved?["bytes"] as? Int
                entry.updated = saved?["date"] as? Date
                return entry
            }
            lastCheck = UserDefaults.standard.object(forKey: ContentBlocker.lastCheckKey) as? Date
        }

        func setLoaded(_ ids: Set<Int>) {
            for index in entries.indices { entries[index].isLoaded = ids.contains(entries[index].id) }
        }

        func set(_ phase: Phase, for id: Int) {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].phase = phase
        }

        func setUpdating(_ updating: Bool) { isUpdating = updating }

        /// Ends any step still shown as in progress. Failures stay until the next try.
        func settle() {
            for index in entries.indices {
                if case .failed = entries[index].phase { continue }
                entries[index].phase = .idle
            }
        }

        func setLastCheck(_ date: Date) { lastCheck = date }

        func record(rules: Int, bytes: Int, for id: Int) {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].rules = rules
            entries[index].bytes = bytes
            entries[index].updated = .now
            UserDefaults.standard.set(["rules": rules, "bytes": bytes, "date": Date.now], forKey: Self.key(id))
        }
    }

    // MARK: - Using the lists

    /// What one web view has attached, so unchanged lists are never re-sent.
    private final class Attachment {
        /// The site the web view is showing, as `site(for:)` names it.
        var site: String?
        var lists: [ObjectIdentifier] = []
        /// The incognito per-site choices, kept in memory; nil in normal tabs.
        let privateRules: PrivateSiteRules?

        init(privateRules: PrivateSiteRules?) { self.privateRules = privateRules }
    }

    /// Gives a new web view whatever lists are ready, and keeps it current
    /// as lists finish loading, update, or get switched on and off.
    ///
    /// Incognito tabs pass `privateRules`: site choices made there are shared by
    /// incognito tabs only and are never saved.
    func install(on controller: WKUserContentController, privateRules: PrivateSiteRules? = nil) {
        attachments.setObject(Attachment(privateRules: privateRules), forKey: controller)
        apply(to: controller)
    }

    /// Call as a web view starts a main-frame navigation, before the page's
    /// requests go out: the new page may be a site with blocking switched off.
    func willNavigate(_ controller: WKUserContentController, to url: URL) {
        guard let attachment = attachments.object(forKey: controller) else { return }
        let site = Self.site(for: url)
        guard attachment.site != site else { return }
        attachment.site = site
        apply(to: controller)
    }

    /// Call when a setting changes: re-applies the lists to every open web view
    /// and fetches any list that was just switched on.
    func settingsChanged() {
        refresh()
        start()
        Task {
            // Built-in lists compile at launch for the categories that were on
            // then; one switched on since needs compiling now.
            if started, let store = WKContentRuleListStore.default() {
                await compileBuiltInLists(in: store)
            }
            await updateIfNeeded()
        }
    }

    private func isEnabled(_ category: Category) -> Bool {
        switch category {
        case .ads: settings.blockAds
        case .trackers: settings.blockTrackers
        case .cookieBanners: settings.blockCookieBanners
        }
    }

    private var activeFilters: [Filter] {
        Self.filters.filter { isEnabled($0.category) }
    }

    func category(ofList identifier: String) -> Category? {
        Self.filters.first { $0.identifier == identifier }?.category
    }

    // MARK: - Per-site settings

    /// The sites each category is switched off for.
    private var offSites = Dictionary(uniqueKeysWithValues: Category.allCases.map {
        ($0, Set(UserDefaults.standard.stringArray(forKey: $0.offSitesKey) ?? []))
    })

    /// The name a site is remembered by: the registered domain, so
    /// `news.bbc.co.uk` and `www.bbc.co.uk` are both "bbc.co.uk". Addresses
    /// and names without a dot ("localhost") are their own site.
    /// nil for anything that isn't a web page.
    static func site(for url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let isAddress = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        if isAddress || !host.contains(".") { return host }
        return PublicSuffixList.effectiveTLDPlusOne(host) ?? host
    }

    /// Whether `category` is blocked on `site`, ignoring the global settings.
    /// The incognito choice, if one was made, wins over the saved one.
    func isBlocking(_ category: Category, on site: String, privateRules: PrivateSiteRules? = nil) -> Bool {
        if let choice = privateRules?.blocking(category, on: site) { return choice }
        return !(offSites[category]?.contains(site) ?? false)
    }

    /// Whether cookie banners are hidden on the page at `url`: switched on
    /// globally and for its site.
    func hidesBanners(on url: URL?, privateRules: PrivateSiteRules? = nil) -> Bool {
        guard settings.blockCookieBanners, let site = Self.site(for: url) else { return false }
        return isBlocking(.cookieBanners, on: site, privateRules: privateRules)
    }

    /// Whether the page at `url` may have cookie consent rejected for it:
    /// switched on globally, and cookie banners not switched off for its site.
    func rejectsConsent(on url: URL?, privateRules: PrivateSiteRules? = nil) -> Bool {
        guard settings.rejectConsent, let site = Self.site(for: url) else { return false }
        return isBlocking(.cookieBanners, on: site, privateRules: privateRules)
    }

    /// Switches one category on or off for a site, in every tab. Pages already
    /// open keep what they loaded until they are reloaded.
    func setBlocking(_ enabled: Bool, _ category: Category, on site: String) {
        var sites = offSites[category] ?? []
        if enabled { sites.remove(site) } else { sites.insert(site) }
        offSites[category] = sites
        UserDefaults.standard.set(sites.sorted(), forKey: category.offSitesKey)
        refresh()
    }

    /// Switches one category on or off for a site in every incognito tab, until
    /// none is on the site. Nothing is saved; pages already open keep what they
    /// loaded until reloaded.
    func setBlocking(_ enabled: Bool, _ category: Category, on site: String, privateRules: PrivateSiteRules) {
        privateRules.setBlocking(enabled, category, on: site)
        refresh()
    }

    // MARK: - Attaching

    private func lists(for site: String?, privateRules: PrivateSiteRules?) -> [WKContentRuleList] {
        activeFilters.compactMap { filter in
            if let site, !isBlocking(filter.category, on: site, privateRules: privateRules) { return nil }
            return compiled[filter.id]
        }
    }

    private func apply(to controller: WKUserContentController) {
        guard let attachment = attachments.object(forKey: controller) else { return }
        let wanted = lists(for: attachment.site, privateRules: attachment.privateRules)
        let identities = wanted.map(ObjectIdentifier.init)
        guard identities != attachment.lists else { return }
        controller.removeAllContentRuleLists()
        for list in wanted { controller.add(list) }
        attachment.lists = identities
    }

    private func refresh() {
        for controller in attachments.keyEnumerator().allObjects as! [WKUserContentController] {
            apply(to: controller)
        }
    }

    // MARK: - Launch

    /// Looks up the saved lists, then checks for newer ones. Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        Task {
            // Even cached lists are optional during startup and interactions.
            do { try await waitForQuiet() } catch { return }
            await loadSavedLists()
            await updateIfNeeded()
        }
    }

    /// Looks the lists up side by side and attaches each as soon as it's ready,
    /// so a slow one never holds back the others. Lists for categories that are
    /// switched off are left alone.
    private func loadSavedLists() async {
        guard let store = WKContentRuleListStore.default() else { return }
        let began = ContinuousClock.now
        await withTaskGroup(of: (Int, WKContentRuleList?).self) { group in
            for filter in activeFilters {
                group.addTask {
                    // Throws when the list was never compiled: the normal first launch.
                    (filter.id, try? await store.contentRuleList(forIdentifier: filter.identifier))
                }
            }
            for await (id, list) in group {
                guard let list else { continue }
                compiled[id] = list
                refresh()
            }
        }
        await compileBuiltInLists(in: store)
        let took = began.duration(to: .now).components
        log.info("Loaded \(self.compiled.count) saved lists in \(Int(took.seconds) * 1000 + Int(took.attoseconds / 1_000_000_000_000_000)) ms")
    }

    /// Built-in rules need no download, so a missing one is compiled right away.
    /// Compiled copies of rules from older versions of the app are dropped.
    private func compileBuiltInLists(in store: WKContentRuleListStore) async {
        let builtIn = activeFilters.filter { if case .builtIn = $0.source { true } else { false } }
        for filter in builtIn where compiled[filter.id] == nil {
            guard case .builtIn(let json) = filter.source else { continue }
            status.set(.compiling, for: filter.id)
            do {
                compiled[filter.id] = try await store.compileContentRuleList(
                    forIdentifier: filter.identifier, encodedContentRuleList: json
                )
                status.record(rules: json.components(separatedBy: "\"trigger\"").count - 1, bytes: json.utf8.count, for: filter.id)
                status.set(.idle, for: filter.id)
                refresh()
            } catch {
                status.set(.failed(error.localizedDescription), for: filter.id)
                log.error("Compiling built-in list \(filter.id) failed: \(error.localizedDescription)")
            }
        }
        let current = Set(Self.filters.map(\.identifier))
        for identifier in await store.availableIdentifiers() ?? []
        where identifier.hasPrefix(Filter.builtInPrefix) && !current.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    // MARK: - Updating

    /// Checks every list now, without waiting for the app to be quiet.
    /// For the Debug section of Settings.
    func updateNow() {
        isForced = true
        // Not started yet: the launch work ends with a check of its own.
        if started { Task { await updateIfNeeded() } } else { start() }
    }

    /// Waits for the app to be quiet, unless `updateNow()` asked not to.
    private func waitForQuiet() async throws {
        while !isForced, !InteractionBudget.shared.isIdle() {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Fresh installs get the same quiet startup as routine refreshes.
    private func waitForStartup() async throws {
        for _ in 0..<80 where !isForced { try await Task.sleep(for: .milliseconds(100)) }
        try await waitForQuiet()
    }

    private func updateIfNeeded() async {
        // A setting changed mid-update: go around again once this pass is done.
        guard !isUpdating else { needsAnotherPass = true; return }
        let filters = activeFilters.filter { if case .adguard = $0.source { true } else { false } }
        let missing = filters.contains { compiled[$0.id] == nil }
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        let isDue = lastCheck.map { Date.now.timeIntervalSince($0) > Self.updateInterval } ?? true
        guard missing || isDue || isForced else { return }

        isUpdating = true
        status.setUpdating(true)
        defer {
            isUpdating = false
            isForced = false
            status.setUpdating(false)
            status.settle()
        }
        for filter in filters { status.set(.waiting, for: filter.id) }

        do { try await waitForStartup() } catch { return }

        var succeeded = true
        for filter in filters {
            do { try await waitForQuiet() } catch { return }
            if await update(filter) == false { succeeded = false }
        }
        if succeeded {
            UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)
            status.setLastCheck(.now)
        }

        if needsAnotherPass {
            needsAnotherPass = false
            isUpdating = false
            await updateIfNeeded()
        }
    }

    /// Brings one list up to date. Returns false if it couldn't be.
    private func update(_ filter: Filter) async -> Bool {
        guard let url = filter.url else { return true }
        let defaults = UserDefaults.standard
        let etagKey = "contentBlocker.etag.\(filter.id)"
        let cacheFile = Self.cacheDirectory.appending(path: "\(filter.id).txt")
        let hasCachedText = FileManager.default.fileExists(atPath: cacheFile.path)

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        if hasCachedText, let etag = defaults.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        var newETag: String?
        status.set(.downloading, for: filter.id)
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return fail(filter, "No response") }
            switch http.statusCode {
            case 200:
                data = body
                newETag = http.value(forHTTPHeaderField: "ETag")
            case 304:
                // Unchanged. Only rebuild if WebKit lost its compiled copy.
                if compiled[filter.id] != nil { return true }
                let cached = await Task.detached(priority: .utility) { try? Data(contentsOf: cacheFile) }.value
                guard let cached else { return fail(filter, "No saved copy to rebuild from") }
                data = cached
            default:
                return fail(filter, "Server answered \(http.statusCode)")
            }
        } catch {
            log.error("Download of \(filter.id) failed: \(error.localizedDescription)")
            return fail(filter, error.localizedDescription)
        }

        do { try await waitForQuiet() } catch { return false }
        status.set(.converting, for: filter.id)
        let began = ContinuousClock.now
        let converted = await Task.detached(priority: .utility) { Self.convert(data) }.value
        // An empty result would silently switch the list off; keep the old one.
        guard converted.rules > 0 else {
            log.error("Conversion of \(filter.id) produced no rules")
            return fail(filter, "Conversion produced no rules")
        }
        let converting = began.duration(to: .now)

        guard let store = WKContentRuleListStore.default() else { return false }
        do {
            try await waitForQuiet()
            status.set(.compiling, for: filter.id)
            compiled[filter.id] = try await store.compileContentRuleList(
                forIdentifier: filter.identifier, encodedContentRuleList: converted.json
            )
        } catch {
            log.error("Compiling \(filter.id) failed: \(error.localizedDescription)")
            return fail(filter, error.localizedDescription)
        }
        status.record(rules: converted.rules, bytes: data.count, for: filter.id)
        log.info("""
            List \(filter.id): \(converted.rules) rules (\(converted.discarded) discarded, \
            \(converted.errors) errors), \(converted.json.utf8.count / 1024) KB; \
            converted in \(converting.formatted()), compiled in \((began.duration(to: .now) - converting).formatted())
            """)

        // Remember the text only once it has proven good.
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }.value
        if let newETag { defaults.set(newETag, forKey: etagKey) }
        refresh()
        return true
    }

    private func fail(_ filter: Filter, _ reason: String) -> Bool {
        status.set(.failed(reason), for: filter.id)
        return false
    }

    private struct Converted: Sendable {
        let json: String
        let rules: Int
        let discarded: Int
        let errors: Int
    }

    /// Filter text to WebKit's rule format. Slow, so it runs off the main thread.
    private nonisolated static func convert(_ data: Data) -> Converted {
        var text = String(decoding: data, as: UTF8.self)
        text.makeContiguousUTF8() // AdGuard's advice: much faster splitting.
        let lines = text.split(whereSeparator: \.isNewline).map(String.init) // the lists use CRLF
        let result = ContentBlockerConverter().convertArray(
            rules: lines, safariVersion: SafariVersion.autodetect(), advancedBlocking: false
        )
        return Converted(
            json: result.safariRulesJSON, rules: result.safariRulesCount,
            discarded: result.discardedSafariRules, errors: result.errorsCount
        )
    }

    private nonisolated static var cacheDirectory: URL {
        URL.cachesDirectory.appending(path: "ContentBlocker", directoryHint: .isDirectory)
    }
}
