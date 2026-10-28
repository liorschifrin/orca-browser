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
        // Temporary for M1: start with one hard-coded page.
        let first = Tab(url: URL(string: "https://www.google.com"))
        tabs = [first]
        selectedTabID = first.id
    }
}
