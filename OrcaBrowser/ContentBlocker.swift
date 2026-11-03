import ContentBlockerConverter
import Foundation
import OSLog
import PublicSuffixList
import WebKit

/// Blocks ads and trackers in every tab with WebKit's own content blocking.
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

    enum Category { case ads, trackers }

    /// An AdGuard filter, in the variant AdGuard optimizes for Safari.
    struct Filter {
        let id: Int
        let category: Category

        var identifier: String { "orcabrowser.adguard.\(id)" }
        var url: URL { URL(string: "https://filters.adtidy.org/ios/filters/\(id)_optimized.txt")! }
    }

    static let filters = [
        Filter(id: 2, category: .ads),       // AdGuard Base
        Filter(id: 11, category: .ads),      // AdGuard Mobile Ads
        Filter(id: 3, category: .trackers),  // AdGuard Tracking Protection
    ]

    /// AdGuard's lists say they expire after five days.
    private static let updateInterval: TimeInterval = 3 * 24 * 60 * 60
    private static let lastCheckKey = "contentBlocker.lastCheck"

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OrcaBrowser", category: "ContentBlocker")
    private let settings = AppSettings.shared
    private var compiled: [Int: WKContentRuleList] = [:]
    /// What each web view currently has. Weak keys, so closed tabs fall out by themselves.
    private let attachments = NSMapTable<WKUserContentController, Attachment>.weakToStrongObjects()
    private var started = false
    private var isUpdating = false
    private var needsAnotherPass = false

    private init() {}

    // MARK: - Using the lists

    /// What one web view has attached, so unchanged lists are never re-sent.
    private final class Attachment {
        /// The site the web view is showing, as `site(for:)` names it.
        var site: String?
        var lists: [ObjectIdentifier] = []
    }

    /// Gives a new web view whatever lists are ready, and keeps it current
    /// as lists finish loading, update, or get switched on and off.
    func install(on controller: WKUserContentController) {
        attachments.setObject(Attachment(), forKey: controller)
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
        Task { await updateIfNeeded() }
    }

    private func isEnabled(_ category: Category) -> Bool {
        switch category {
        case .ads: settings.blockAds
        case .trackers: settings.blockTrackers
        }
    }

    private var activeFilters: [Filter] {
        Self.filters.filter { isEnabled($0.category) }
    }

    func category(ofList identifier: String) -> Category? {
        Self.filters.first { $0.identifier == identifier }?.category
    }

    // MARK: - Per-site settings

    private static let adsOffKey = "contentBlocker.adsOffSites"
    private static let trackersOffKey = "contentBlocker.trackersOffSites"

    private var adsOffSites = Set(UserDefaults.standard.stringArray(forKey: ContentBlocker.adsOffKey) ?? [])
    private var trackersOffSites = Set(UserDefaults.standard.stringArray(forKey: ContentBlocker.trackersOffKey) ?? [])

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
    func isBlocking(_ category: Category, on site: String) -> Bool {
        switch category {
        case .ads: !adsOffSites.contains(site)
        case .trackers: !trackersOffSites.contains(site)
        }
    }

    /// Switches one category on or off for a site, in every tab. Pages already
    /// open keep what they loaded until they are reloaded.
    func setBlocking(_ enabled: Bool, _ category: Category, on site: String) {
        switch category {
        case .ads:
            if enabled { adsOffSites.remove(site) } else { adsOffSites.insert(site) }
            UserDefaults.standard.set(adsOffSites.sorted(), forKey: Self.adsOffKey)
        case .trackers:
            if enabled { trackersOffSites.remove(site) } else { trackersOffSites.insert(site) }
            UserDefaults.standard.set(trackersOffSites.sorted(), forKey: Self.trackersOffKey)
        }
        refresh()
    }

    // MARK: - Attaching

    private func lists(for site: String?) -> [WKContentRuleList] {
        activeFilters.compactMap { filter in
            if let site, !isBlocking(filter.category, on: site) { return nil }
            return compiled[filter.id]
        }
    }

    private func apply(to controller: WKUserContentController) {
        guard let attachment = attachments.object(forKey: controller) else { return }
        let wanted = lists(for: attachment.site)
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
            do { try await InteractionBudget.shared.waitForIdle() } catch { return }
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
        let took = began.duration(to: .now).components
        log.info("Loaded \(self.compiled.count) saved lists in \(Int(took.seconds) * 1000 + Int(took.attoseconds / 1_000_000_000_000_000)) ms")
    }

    // MARK: - Updating

    private func updateIfNeeded() async {
        // A setting changed mid-update: go around again once this pass is done.
        guard !isUpdating else { needsAnotherPass = true; return }
        let filters = activeFilters
        let missing = filters.contains { compiled[$0.id] == nil }
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        let isDue = lastCheck.map { Date.now.timeIntervalSince($0) > Self.updateInterval } ?? true
        guard missing || isDue else { return }

        isUpdating = true
        defer { isUpdating = false }

        // Fresh installs receive the same quiet startup as routine refreshes.
        do {
            try await Task.sleep(for: .seconds(8))
            try await InteractionBudget.shared.waitForIdle()
        } catch { return }

        var succeeded = true
        for filter in filters {
            do { try await InteractionBudget.shared.waitForIdle() } catch { return }
            if await update(filter) == false { succeeded = false }
        }
        if succeeded { UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey) }

        if needsAnotherPass {
            needsAnotherPass = false
            isUpdating = false
            await updateIfNeeded()
        }
    }

    /// Brings one list up to date. Returns false if it couldn't be.
    private func update(_ filter: Filter) async -> Bool {
        let defaults = UserDefaults.standard
        let etagKey = "contentBlocker.etag.\(filter.id)"
        let cacheFile = Self.cacheDirectory.appending(path: "\(filter.id).txt")
        let hasCachedText = FileManager.default.fileExists(atPath: cacheFile.path)

        var request = URLRequest(url: filter.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        if hasCachedText, let etag = defaults.string(forKey: etagKey) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        var newETag: String?
        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            switch http.statusCode {
            case 200:
                data = body
                newETag = http.value(forHTTPHeaderField: "ETag")
            case 304:
                // Unchanged. Only rebuild if WebKit lost its compiled copy.
                if compiled[filter.id] != nil { return true }
                let cached = await Task.detached(priority: .utility) { try? Data(contentsOf: cacheFile) }.value
                guard let cached else { return false }
                data = cached
            default:
                return false
            }
        } catch {
            log.error("Download of \(filter.id) failed: \(error.localizedDescription)")
            return false
        }

        do { try await InteractionBudget.shared.waitForIdle() } catch { return false }
        let began = ContinuousClock.now
        let converted = await Task.detached(priority: .utility) { Self.convert(data) }.value
        // An empty result would silently switch the list off; keep the old one.
        guard converted.rules > 0 else {
            log.error("Conversion of \(filter.id) produced no rules")
            return false
        }
        let converting = began.duration(to: .now)

        guard let store = WKContentRuleListStore.default() else { return false }
        do {
            try await InteractionBudget.shared.waitForIdle()
            compiled[filter.id] = try await store.compileContentRuleList(
                forIdentifier: filter.identifier, encodedContentRuleList: converted.json
            )
        } catch {
            log.error("Compiling \(filter.id) failed: \(error.localizedDescription)")
            return false
        }
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
