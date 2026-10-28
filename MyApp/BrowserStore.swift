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
    func open(_ input: String) {
        guard let url = Destination.url(for: input) else { return }

        if let current = selectedTab, current.isBlank {
            current.load(url)
        } else {
            let tab = Tab(url: url)
            tabs.append(tab)
            selectedTabID = tab.id
        }
    }
}
