import OSLog
import SwiftUI

/// The single source of truth for "what tabs exist and which one is showing".
@Observable
final class BrowserStore {
    var tabs: [Tab]
    var selectedTabID: Tab.ID
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
    private(set) var isRestoringSession = true
    @ObservationIgnored private var hasStartedRestoring = false

    init() {
        // No disk reads or WebKit construction before the first frame.
        let first = Tab()
        tabs = [first]
        selectedTabID = first.id
        watch([first])
        markUsed(first)
    }

    func restoreSession() async {
        guard !hasStartedRestoring else { return }
        hasStartedRestoring = true
        let interval = PerformanceTrace.signposter.beginInterval("Session restoration")
        defer { PerformanceTrace.signposter.endInterval("Session restoration", interval) }
        let initialID = selectedTabID
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
        if let current = selectedTab, !current.isBlank {
            current.activate()
            current.peek?.tab.activate()
        }
    }

    /// A user who navigated while disk work ran keeps their page and selection.
    /// The saved tabs join behind it rather than replacing it.
    func applyRestoredTabs(_ restored: [Tab], selectedID: UUID?, initialID: UUID) {
        guard !restored.isEmpty else { return }
        let untouched = tabs.count == 1 && tabs[0].id == initialID && tabs[0].isBlank
        let kept = untouched ? [] : tabs
        watch(restored)
        recencyClock = max(recencyClock, restored.map(\.recency).max() ?? 0)
        for tab in kept.sorted(by: { $0.recency < $1.recency }) { markUsed(tab) }
        tabs = restored + kept
        if untouched {
            let current = restored.first { $0.id == selectedID }
                ?? restored.max { $0.recency < $1.recency }!
            selectedTabID = current.id
            current.lastOpenedAt = .now
        }
    }

    private func watch(_ newTabs: [Tab]) {
        for tab in newTabs {
            tab.onChange = { [weak self] in self?.scheduleSave() }
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
        TabPersistence.save(tabs: tabs, selectedID: selectedTabID)
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
        for tab in tabs where tab.id != selectedTabID {
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
        let closing = tabs.filter {
            Self.shouldAutoArchive($0, selectedID: selectedTabID, days: settings.autoArchiveDays, now: now)
        }
        guard !closing.isEmpty,
              let entries = try? TabPersistence.archive(closing, among: tabs, selectedID: selectedTabID, now: now)
        else { return }

        let ids = Set(closing.map(\.id))
        tabs.removeAll { ids.contains($0.id) }
        for tab in closing { tab.teardown() }
        archivedTabs = entries
        save()
    }

    func restoreArchived(_ entry: ArchivedTab, inBackground: Bool) throws {
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
    /// If the current tab is still blank, it's reused instead, so we don't
    /// leave an empty tab behind.
    func open(_ input: String) {
        let interval = PerformanceTrace.signposter.beginInterval("New tab submission")
        defer { PerformanceTrace.signposter.endInterval("New tab submission", interval) }
        InteractionBudget.shared.interacted()
        guard let url = Destination.url(for: input) else { return }

        if let current = selectedTab, current.isBlank {
            current.lastOpenedAt = .now
            current.load(url, input: input)
        } else {
            // Navigation never waits for a picture. Cards use a cached image
            // or a placeholder until a later idle capture.
            let tab = Tab(url: url, input: input)
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

    /// Opens `url` in a new tab behind the current one, which stays showing.
    func openInBackground(_ url: URL) {
        let tab = Tab(url: url)
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

    /// Applies the Shorts setting to every tab that has a live web view.
    /// Tabs that load later pick it up when their web view is created.
    func applyShortsSetting(_ enabled: Bool) {
        for tab in tabs where tab.isLoaded {
            tab.setHidesShorts(enabled)
        }
    }

    /// Applies the Reddit pop-up setting to every tab that has a live web view.
    func applyRedditPromptSetting(_ enabled: Bool) {
        for tab in tabs where tab.isLoaded {
            tab.setBlocksRedditPrompt(enabled)
        }
    }

    func select(_ tab: Tab) {
        // A page left behind can't wait on a dialog nobody can see.
        if tab.id != selectedTabID {
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
        let closing = tabs.filter { !$0.isBlank }
        guard !isRestoringSession, !closing.isEmpty else { return }
        // If they can't be written, they stay open rather than get lost.
        guard (try? TabPersistence.stashClosed(tabs, selectedID: selectedTabID)) != nil else { return }

        for tab in tabs { tab.teardown() }
        replaceWithBlankTab()
        closedTabCount += closing.count
        save()
    }

    /// Brings back the tabs put away by `closeAll`, none of them loaded except
    /// the current one. If only a blank tab is open they replace it and the
    /// most recently used becomes current; otherwise they join the open tabs,
    /// older than all of them, and the current tab stays put.
    func restoreClosed() {
        guard !isRestoringSession else { return }
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
}
