import OSLog
import SwiftUI

/// The single source of truth for "what tabs exist and which one is showing".
///
/// There are two spaces of tabs: the normal ones (saved to disk, per-tab
/// incognito tabs included) and the incognito window, which exists only in
/// memory. `tabs` and `selectedTabID` are those of the space being shown, so
/// everything that opens, selects or closes a tab works in either one. What
/// is only for normal tabs (saving, archiving, restoring) says so.
@Observable
final class BrowserStore {
    enum Space { case normal, incognito }
    private(set) var space = Space.normal

    private var normalTabs: [Tab]
    private var normalSelectedID: Tab.ID
    /// Created when first entered, and gone when it is closed.
    private(set) var incognitoWindow: IncognitoWindow?

    var tabs: [Tab] {
        get { space == .normal ? normalTabs : incognitoWindow?.tabs ?? [] }
        set {
            if space == .normal { normalTabs = newValue } else { incognitoWindow?.tabs = newValue }
        }
    }
    var selectedTabID: Tab.ID {
        get { space == .normal ? normalSelectedID : incognitoWindow?.selectedTabID ?? normalSelectedID }
        set {
            if space == .normal { normalSelectedID = newValue } else { incognitoWindow?.selectedTabID = newValue }
        }
    }
    /// Every tab in both spaces, for settings that reach all live pages.
    private var allTabs: [Tab] { normalTabs + (incognitoWindow?.tabs ?? []) }

    /// A switch that slides the new tab in from the right, like moving to
    /// the next app. The old tab stays on screen until the slide ends.
    struct Slide: Equatable {
        let incoming: Tab.ID
        let outgoing: Tab.ID
    }
    var slide: Slide?
    /// How many tabs "Close All" has put away. They live on disk only.
    private(set) var closedTabCount = 0
    private(set) var archivedTabs: [ArchivedTab] = []

    /// Counts up every time a tab becomes the current one. Each tab remembers
    /// the value it got, which gives us "most recently used" ordering.
    private var recencyClock = 0

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    /// Oldest-used first, current tab last. This is the switcher's order:
    /// the current tab is always rightmost, and the tab you were on before it
    /// sits immediately to its left.
    var tabsByRecency: [Tab] {
        tabs.sorted { $0.recency < $1.recency }
    }

    /// Only this many tabs (the selected one and the most recent others)
    /// keep a live web view; the rest are unloaded to save memory.
    static let liveTabLimit = 3
    /// A tab you haven't looked at for this long is unloaded, even within the limit.
    static let idleLimit: TimeInterval = 5 * 60

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var restoreObserver: NSObjectProtocol?
    private(set) var isRestoringSession = true
    @ObservationIgnored private var hasStartedRestoring = false

    init() {
        // No disk reads or WebKit construction before the first frame.
        let first = Tab()
        normalTabs = [first]
        normalSelectedID = first.id
        watch([first])
        markUsed(first)
        restoreObserver = NotificationCenter.default.addObserver(
            forName: PictureInPictureRestoreHook.didTapRestore, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pictureInPictureRestoreTapped() }
        }
    }

    func restoreSession() async {
        guard !hasStartedRestoring else { return }
        hasStartedRestoring = true
        let interval = PerformanceTrace.signposter.beginInterval("Session restoration")
        defer { PerformanceTrace.signposter.endInterval("Session restoration", interval) }
        let initialID = normalSelectedID
        let saved = await TabPersistence.loadStartup()
        var restored: [Tab] = []
        for record in saved.tabs {
            restored.append(TabPersistence.restoreRecord(record, files: saved.files))
            if restored.count.isMultiple(of: 20) { await Task.yield() }
        }
        applyRestoredTabs(restored, selectedID: saved.selectedID, initialID: initialID)
        closedTabCount = saved.closedCount
        archivedTabs = saved.archived
        isRestoringSession = false
        // An early background transition must flush the merged session too;
        // waiting for foreground idle here could otherwise lose the user's tab.
        guard InteractionBudget.shared.isForeground else {
            save()
            return
        }
        scheduleSave()
        // The shell and metadata get a turn to render before WebKit starts.
        await Task.yield()
        if space == .normal, let current = selectedTab, !current.isBlank {
            current.activate()
            current.peek?.tab.activate()
        }
    }

    /// A user who navigated while disk work ran keeps their page and selection.
    /// The saved tabs join behind it rather than replacing it.
    func applyRestoredTabs(_ restored: [Tab], selectedID: UUID?, initialID: UUID) {
        guard !restored.isEmpty else { return }
        let untouched = normalTabs.count == 1 && normalTabs[0].id == initialID && normalTabs[0].isBlank
        let kept = untouched ? [] : normalTabs
        watch(restored)
        recencyClock = max(recencyClock, restored.map(\.recency).max() ?? 0)
        for tab in kept.sorted(by: { $0.recency < $1.recency }) { markUsed(tab) }
        normalTabs = restored + kept
        if untouched {
            let current = restored.first { $0.id == selectedID }
                ?? restored.max { $0.recency < $1.recency }!
            normalSelectedID = current.id
            current.lastOpenedAt = .now
        }
    }

    /// Switches to the tab whose video you came back to, sliding it in.
    private func returnToVideo(in tab: Tab) {
        guard tab.id != selectedTabID else { return }
        slide = Slide(incoming: tab.id, outgoing: selectedTabID)
        // The picture in picture window is already on its way back.
        select(tab, exitingPictureInPicture: false)
    }

    /// You tapped "return to app" in the picture in picture window.
    private func pictureInPictureRestoreTapped() {
        guard let tab = tabs.first(where: \.isInPictureInPicture) else { return }
        tab.pictureInPictureRestoreTapped()
        returnToVideo(in: tab)
    }

    private func watch(_ newTabs: [Tab]) {
        for tab in newTabs {
            tab.onChange = { [weak self] in self?.scheduleSave() }
            tab.onPictureInPictureReturn = { [weak self, weak tab] in
                guard let self, let tab else { return }
                returnToVideo(in: tab)
            }
        }
    }

    // MARK: - Saving and memory

    /// Saves soon, but not on every little change.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            try? await InteractionBudget.shared.waitForIdle()
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        saveTask?.cancel()
        guard !isRestoringSession else { return }
        TabPersistence.save(tabs: normalTabs, selectedID: normalSelectedID)
    }

    /// Unloads tabs beyond the most recent few, and ones left alone too long.
    /// The selected tab is never unloaded. A held link's page has a web view
    /// of its own, so it takes a place too, and goes before its tab does.
    func enforceMemoryPolicy() {
        let now = Date.now
        guard let selected = selectedTab else { return }
        selected.lastViewed = now

        var places = 1 + (selected.peek?.tab.isLoaded == true ? 1 : 0)
        let others = tabs
            .filter { $0.isLoaded && !$0.isBlank && $0.id != selectedTabID }
            .sorted { $0.recency > $1.recency }
        for tab in others {
            if places >= Self.liveTabLimit || now.timeIntervalSince(tab.lastViewed) > Self.idleLimit {
                tab.unload()
                continue
            }
            places += 1
            if let peekTab = tab.peek?.tab, peekTab.isLoaded {
                if places >= Self.liveTabLimit { peekTab.unload() } else { places += 1 }
            }
        }
    }

    /// iOS says memory is short: keep only the page being looked at.
    func unloadBackgroundTabs() {
        for tab in allTabs where tab.id != selectedTabID {
            tab.unload()
        }
        CardThumbnails.shared.removeAll()
        // Saving also lets go of the unloaded tabs' pictures.
        save()
    }

    private func markUsed(_ tab: Tab) {
        recencyClock += 1
        tab.recency = recencyClock
    }

    func archiveInactiveTabs(now: Date = .now) {
        let settings = AppSettings.shared
        guard !isRestoringSession, settings.autoArchiveTabs else { return }
        let closing = normalTabs.filter {
            Self.shouldAutoArchive($0, selectedID: normalSelectedID, days: settings.autoArchiveDays, now: now)
        }
        guard !closing.isEmpty,
              let entries = try? TabPersistence.archive(closing, among: normalTabs, selectedID: normalSelectedID, now: now)
        else { return }

        let ids = Set(closing.map(\.id))
        normalTabs.removeAll { ids.contains($0.id) }
        for tab in closing { tab.teardown() }
        archivedTabs = entries
        save()
    }

    func restoreArchived(_ entry: ArchivedTab, inBackground: Bool) throws {
        guard space == .normal else { return }
        if let existing = tabs.first(where: { $0.id == entry.id }) {
            if !inBackground { select(existing) }
        } else {
            let tab = try TabPersistence.restoreArchived(entry)
            tab.lastOpenedAt = .now
            watch([tab])
            tabs.append(tab)
            markUsed(tab)
            if inBackground {
                if let current = selectedTab { markUsed(current) }
            } else {
                select(tab)
            }
        }
        save()
        archivedTabs = try TabPersistence.removeArchived(entry.id)
    }

    func deleteArchived(_ entry: ArchivedTab) throws {
        archivedTabs = try TabPersistence.removeArchived(entry.id)
    }

    static func shouldAutoArchive(_ tab: Tab, selectedID: Tab.ID, days: Int, now: Date) -> Bool {
        days > 0 && !tab.isBlank && tab.id != selectedID
            && now.timeIntervalSince(tab.lastOpenedAt) >= Double(days) * 24 * 60 * 60
    }

    /// Opens whatever the user typed (a URL or a search) in a new tab.
    /// Reuses a blank tab only when its privacy matches the requested mode.
    /// Without an explicit mode, new tabs inherit the current tab's privacy.
    func open(_ input: String, isIncognito: Bool? = nil) {
        open(SearchSubmission(text: input), isIncognito: isIncognito)
    }

    /// Opens a resolved submission in a compatible blank tab or a new tab, retaining its search provider.
    func open(_ submission: SearchSubmission, isIncognito: Bool? = nil) {
        let interval = PerformanceTrace.signposter.beginInterval("New tab submission")
        defer { PerformanceTrace.signposter.endInterval("New tab submission", interval) }
        InteractionBudget.shared.interacted()
        guard let url = submission.resolvedURL else { return }
        // Everything opened inside the incognito window is private.
        let privateMode = space == .incognito || (isIncognito ?? selectedTab?.isIncognito ?? false)

        if let current = selectedTab, current.isBlank, current.isIncognito == privateMode {
            current.lastOpenedAt = .now
            current.load(url, input: submission.text, providerID: submission.providerID)
        } else {
            // Navigation never waits for a picture. Cards use a cached image
            // or a placeholder until a later idle capture.
            let tab = makeTab(url: url, input: submission.text, providerID: submission.providerID, isIncognito: privateMode)
            watch([tab])
            selectedTab?.lastViewed = .now
            selectedTab?.lastOpenedAt = .now
            tabs.append(tab)
            selectedTabID = tab.id
            markUsed(tab)
            enforceMemoryPolicy()
        }
        scheduleSave()
    }

    /// Starts a private search without copying the previous tab's address.
    func newIncognitoTab() {
        let tab = makeTab(isIncognito: true)
        watch([tab])
        tabs.append(tab)
        select(tab)
    }

    /// A new tab for the space being shown: in the incognito window it joins
    /// the window's session.
    private func makeTab(url: URL? = nil, input: String? = nil, providerID: String? = nil, isIncognito: Bool) -> Tab {
        Tab(url: url, input: input, providerID: providerID, isIncognito: isIncognito, session: space == .incognito ? incognitoWindow?.session : nil)
    }

    /// Opens `url` in a new tab behind the current one, which stays showing.
    func openInBackground(_ url: URL) {
        let tab = makeTab(url: url, isIncognito: selectedTab?.isIncognito ?? false)
        watch([tab])
        tabs.append(tab)
        markUsed(tab)
        if let current = selectedTab { markUsed(current) }
        enforceMemoryPolicy()
        scheduleSave()
    }

    /// Adopt the preview's actual tab and web view, preserving page state.
    func adoptPreview(_ tab: Tab, inBackground: Bool) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        tab.lastOpenedAt = .now
        watch([tab])
        tabs.append(tab)
        markUsed(tab)
        if inBackground {
            // Keep the visible page last in the switcher's recency order.
            if let current = selectedTab { markUsed(current) }
        } else {
            selectedTab?.lastViewed = .now
            selectedTab?.lastOpenedAt = .now
            selectedTabID = tab.id
        }
        enforceMemoryPolicy()
        scheduleSave()
    }

    /// Applies the Shorts hiding setting to every tab that has a live web view.
    /// Tabs that load later pick it up when their web view is created.
    func applyShortsSetting(_ enabled: Bool) {
        for tab in allTabs where tab.isLoaded {
            tab.setHidesShorts(enabled)
        }
    }

    /// Applies the "open Shorts as videos" setting the same way.
    func applyOpensShortsAsVideosSetting(_ enabled: Bool) {
        for tab in allTabs where tab.isLoaded {
            tab.setOpensShortsAsVideos(enabled)
        }
    }

    /// Applies the Reddit pop-up setting to every tab that has a live web view.
    func applyRedditPromptSetting(_ enabled: Bool) {
        for tab in allTabs where tab.isLoaded {
            tab.setBlocksRedditPrompt(enabled)
        }
    }

    /// Applies the YouTube top bar settings to every tab with a live page.
    func applyYouTubeSettings(_ settings: AppSettings) {
        for tab in allTabs where tab.isLoaded {
            tab.applyYouTubeSettings(settings)
        }
    }

    /// Makes `tab` the current tab. If its video is in picture in picture, the
    /// video comes back into the page, unless the caller says it's already
    /// doing that.
    func select(_ tab: Tab, exitingPictureInPicture: Bool = true) {
        // A page left behind can't wait on a dialog nobody can see.
        if tab.id != selectedTabID {
            selectedTab?.pauseVideos()
            selectedTab?.answerDialog(.cancel)
            selectedTab?.peek?.tab.answerDialog(.cancel)
        }
        selectedTab?.lastViewed = .now
        selectedTab?.lastOpenedAt = .now
        tab.lastOpenedAt = .now
        // Bring the page back if it had been unloaded.
        tab.activate()
        tab.peek?.tab.activate()
        selectedTabID = tab.id
        if exitingPictureInPicture { tab.exitPictureInPicture() }
        markUsed(tab)
        enforceMemoryPolicy()
        scheduleSave()
    }

    /// Closes a tab. Returns true if that was the last one and a fresh blank
    /// tab had to take its place (the app is never left without a tab).
    @discardableResult
    func close(_ tab: Tab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        let wasSelected = tab.id == selectedTabID

        tabs.remove(at: index)
        tab.teardown()

        if tabs.isEmpty {
            // The last incognito tab closing closes the window itself.
            if space == .incognito {
                closeIncognito()
                return false
            }
            replaceWithBlankTab()
            scheduleSave()
            return true
        }
        if wasSelected, let previous = tabs.max(by: { $0.recency < $1.recency }) {
            // Fall back to the tab you were on before this one.
            previous.activate()
            previous.lastOpenedAt = .now
            selectedTabID = previous.id
            enforceMemoryPolicy()
        }
        scheduleSave()
        return false
    }

    private func replaceWithBlankTab() {
        let blank = Tab()
        watch([blank])
        tabs = [blank]
        selectedTabID = blank.id
        markUsed(blank)
    }

    // MARK: - Closing and restoring everything

    /// Puts every open tab away on disk and leaves a single blank tab. Once
    /// the tabs are closed nothing of them stays in memory: their web views
    /// are torn down and the tabs themselves released.
    func closeAll() {
        let closing = tabs.filter { !$0.isBlank || $0.isIncognito }
        guard space == .normal, !isRestoringSession, !closing.isEmpty else { return }
        // If they can't be written, they stay open rather than get lost.
        guard (try? TabPersistence.stashClosed(tabs, selectedID: selectedTabID)) != nil else { return }

        for tab in tabs { tab.teardown() }
        replaceWithBlankTab()
        closedTabCount += closing.filter { !$0.isIncognito }.count
        save()
    }

    /// Brings back the tabs put away by `closeAll`, none of them loaded except
    /// the current one. If only a blank tab is open they replace it and the
    /// most recently used becomes current; otherwise they join the open tabs,
    /// older than all of them, and the current tab stays put.
    func restoreClosed() {
        guard space == .normal, !isRestoringSession else { return }
        let restored = TabPersistence.unstashClosed()
        guard !restored.isEmpty else { return }

        let replacing = tabs.allSatisfy(\.isBlank)
        if replacing {
            for tab in tabs { tab.teardown() }
        }
        let kept = replacing ? [] : tabs

        watch(restored)
        for tab in restored + kept.sorted(by: { $0.recency < $1.recency }) {
            markUsed(tab)
        }
        for tab in restored { tab.lastOpenedAt = .now }
        tabs = restored + kept
        if replacing, let latest = restored.last {
            latest.activate()
            latest.peek?.tab.activate()
            selectedTabID = latest.id
        }
        closedTabCount = 0
        enforceMemoryPolicy()
        // Only once they're saved again is it safe to forget the closed list.
        save()
        TabPersistence.clearClosed()
    }

    // MARK: - The incognito window

    enum IncognitoEntry: Equatable {
        /// You are in the window.
        case entered
        /// Tabs are waiting in the locked window: ask whether to continue
        /// them (`continueIncognito`, which needs Face ID) or start over
        /// (`startFreshIncognito`, which needs nothing, as it destroys them).
        case needsChoice
    }

    /// Goes into the incognito window, unless it has tabs in it: those are
    /// locked, and the choice is up to the caller.
    func enterIncognito() -> IncognitoEntry {
        guard space == .normal else { return .entered }
        if incognitoWindow?.hasContent == true { return .needsChoice }
        if incognitoWindow == nil { incognitoWindow = IncognitoWindow() }
        switchSpace(to: .incognito)
        return .entered
    }

    enum IncognitoUnlock: Equatable {
        case entered
        /// You are still outside. A message says why, or none if you cancelled.
        case denied(String?)
    }

    /// Opens the locked window's tabs, once the person holding the phone has
    /// proved who they are.
    func continueIncognito(using authenticator: some IncognitoAuthenticating) async -> IncognitoUnlock {
        guard space == .normal, incognitoWindow != nil else { return .entered }
        if let failure = await authenticator.authenticate() {
            return .denied(failure.isEmpty ? nil : failure)
        }
        // The window may have been closed while the prompt was up.
        guard space == .normal, incognitoWindow != nil else { return .entered }
        switchSpace(to: .incognito)
        return .entered
    }

    func startFreshIncognito() {
        guard let window = incognitoWindow else { return }
        window.reset()
        switchSpace(to: .incognito)
    }

    /// Back to the normal tabs. The window stays, locked, unless nothing was
    /// opened in it.
    func leaveIncognito() {
        guard space == .incognito else { return }
        switchSpace(to: .normal)
        if incognitoWindow?.hasContent == false { closeIncognito() }
    }

    /// Closes every incognito tab and forgets what they stored.
    func closeIncognito() {
        if space == .incognito { switchSpace(to: .normal) }
        incognitoWindow?.close()
        incognitoWindow = nil
    }

    private func switchSpace(to newSpace: Space) {
        guard newSpace != space else { return }
        if let leaving = selectedTab {
            leaving.pauseVideos()
            leaving.answerDialog(.cancel)
            leaving.peek?.tab.answerDialog(.cancel)
        }
        slide = nil
        if space == .incognito {
            // Nothing of a locked window stays on screen or playing.
            for tab in tabs { tab.unload() }
            incognitoWindow?.didLeave()
        }
        space = newSpace
        if newSpace == .incognito { incognitoWindow?.didEnter() }
        if let entering = selectedTab {
            entering.activate()
            entering.peek?.tab.activate()
            entering.lastOpenedAt = .now
        }
        enforceMemoryPolicy()
    }
}
