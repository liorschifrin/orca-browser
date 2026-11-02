import SwiftUI

/// The single source of truth for "what tabs exist and which one is showing".
@Observable
final class BrowserStore {
    var tabs: [Tab]
    var selectedTabID: Tab.ID

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

    init() {
        if let saved = TabPersistence.load() {
            tabs = saved.tabs
            recencyClock = saved.tabs.map(\.recency).max() ?? 0
            // The saved current tab, else the most recently used.
            let current = saved.tabs.first { $0.id == saved.selectedID }
                ?? saved.tabs.max { $0.recency < $1.recency }!
            selectedTabID = current.id
            current.activate()
            current.peek?.tab.activate()
            watch(saved.tabs)
        } else {
            // The app always has at least one tab; it starts out blank.
            let first = Tab()
            tabs = [first]
            selectedTabID = first.id
            watch([first])
            markUsed(first)
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
            save()
        }
    }

    func save() {
        saveTask?.cancel()
        TabPersistence.save(tabs: tabs, selectedID: selectedTabID)
    }

    /// Unloads tabs beyond the most recent few, and ones left alone too long.
    /// The selected tab is never unloaded.
    func enforceMemoryPolicy() {
        let now = Date.now
        selectedTab?.lastViewed = now

        let live = tabs
            .filter { $0.isLoaded && !$0.isBlank }
            .sorted { $0.recency > $1.recency }
        for (rank, tab) in live.enumerated() where tab.id != selectedTabID {
            if rank >= Self.liveTabLimit || now.timeIntervalSince(tab.lastViewed) > Self.idleLimit {
                tab.unload()
            }
        }
    }

    /// iOS says memory is short: keep only the page being looked at.
    func unloadBackgroundTabs() {
        for tab in tabs where tab.id != selectedTabID {
            tab.unload()
        }
    }

    private func markUsed(_ tab: Tab) {
        recencyClock += 1
        tab.recency = recencyClock
    }

    /// Opens whatever the user typed (a URL or a search) in a new tab.
    /// If the current tab is still blank, it's reused instead, so we don't
    /// leave an empty tab behind.
    func open(_ input: String) async {
        guard let url = Destination.url(for: input) else { return }

        if let current = selectedTab, current.isBlank {
            current.load(url)
        } else {
            // Photograph the page we're leaving, for its card in the switcher.
            await selectedTab?.captureSnapshot()
            let tab = Tab(url: url)
            watch([tab])
            selectedTab?.lastViewed = .now
            tabs.append(tab)
            selectedTabID = tab.id
            markUsed(tab)
            enforceMemoryPolicy()
        }
        scheduleSave()
    }

    /// Adopt the preview's actual tab and web view, preserving page state.
    func adoptPreview(_ tab: Tab, inBackground: Bool) {
        guard !tabs.contains(where: { $0.id == tab.id }) else { return }
        watch([tab])
        tabs.append(tab)
        markUsed(tab)
        if inBackground {
            // Keep the visible page last in the switcher's recency order.
            if let current = selectedTab { markUsed(current) }
        } else {
            selectedTab?.lastViewed = .now
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

    func select(_ tab: Tab) {
        selectedTab?.lastViewed = .now
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
            let blank = Tab()
            watch([blank])
            tabs = [blank]
            selectedTabID = blank.id
            markUsed(blank)
            scheduleSave()
            return true
        }
        if wasSelected, let previous = tabs.max(by: { $0.recency < $1.recency }) {
            // Fall back to the tab you were on before this one.
            previous.activate()
            selectedTabID = previous.id
            enforceMemoryPolicy()
        }
        scheduleSave()
        return false
    }
}
