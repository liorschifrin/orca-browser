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

    init() {
        // The app always has at least one tab; it starts out blank.
        let first = Tab()
        tabs = [first]
        selectedTabID = first.id
        markUsed(first)
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
            tabs.append(tab)
            selectedTabID = tab.id
            markUsed(tab)
        }
    }

    func select(_ tab: Tab) {
        selectedTabID = tab.id
        markUsed(tab)
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
            tabs = [blank]
            selectedTabID = blank.id
            markUsed(blank)
            return true
        }
        if wasSelected, let previous = tabs.max(by: { $0.recency < $1.recency }) {
            // Fall back to the tab you were on before this one.
            selectedTabID = previous.id
        }
        return false
    }
}
