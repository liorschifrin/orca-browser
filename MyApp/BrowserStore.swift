import SwiftUI

/// The single source of truth for "what tabs exist and which one is showing".
@Observable
final class BrowserStore {
    var tabs: [Tab]
    var selectedTabID: Tab.ID

    var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    init() {
        // The app always has at least one tab; it starts out blank.
        let first = Tab()
        tabs = [first]
        selectedTabID = first.id
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
        }
    }

    func select(_ tab: Tab) {
        selectedTabID = tab.id
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
            return true
        }
        if wasSelected {
            // Land on the neighbor that slid into the closed tab's place.
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        return false
    }
}
