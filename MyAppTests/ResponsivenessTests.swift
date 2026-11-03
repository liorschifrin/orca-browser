import Foundation
import Testing
@testable import MyApp

@MainActor
struct ResponsivenessTests {
    private func restored(_ name: String, recency: Int = 1) -> Tab {
        Tab(restoring: SavedTab(id: UUID(), url: URL(string: "https://\(name).example"),
                               title: name, recency: recency), hasSnapshot: false, favicon: nil)
    }

    @Test func initialShellDoesNotConstructWebKit() {
        let store = BrowserStore()
        #expect(store.isRestoringSession)
        #expect(store.tabs.count == 1)
        #expect(store.selectedTab?.isBlank == true)
        #expect(store.selectedTab?.isLoaded == false)
    }

    @Test func selectingEmptyTabDoesNotConstructWebKit() {
        let store = BrowserStore()
        let blank = store.tabs[0]
        store.select(blank)
        #expect(!blank.isLoaded)
    }

    @Test func newTabSubmissionIsSynchronousAndKeepsLeavingCard() {
        let store = BrowserStore()
        let previous = restored("previous")
        store.tabs = [previous]
        store.selectedTabID = previous.id
        // This synchronous API cannot await screenshot generation.
        store.open("https://new.example")
        #expect(store.tabs.count == 2)
        #expect(store.selectedTabID != previous.id)
        #expect(store.selectedTab?.searchText == "https://new.example")
        #expect(!previous.hasSnapshot)
        for tab in store.tabs { tab.teardown() }
    }

    @Test func restorationSelectsSavedTabWithoutLoadingPages() {
        let store = BrowserStore()
        let first = restored("first")
        let second = restored("second", recency: 2)
        store.applyRestoredTabs([first, second], selectedID: first.id, initialID: store.selectedTabID)
        #expect(store.selectedTabID == first.id)
        #expect(store.tabs.count == 2)
        #expect(store.tabs.allSatisfy { !$0.isLoaded })
    }

    @Test func lateRestorationPreservesUserTabAndSelection() {
        let store = BrowserStore()
        let initialID = store.selectedTabID
        let userTab = restored("user")
        store.tabs = [userTab]
        store.selectedTabID = userTab.id
        let savedTab = restored("saved", recency: 100)
        store.applyRestoredTabs([savedTab], selectedID: savedTab.id, initialID: initialID)
        #expect(store.selectedTabID == userTab.id)
        #expect(store.tabs.map(\.id) == [savedTab.id, userTab.id])
        #expect(userTab.recency > savedTab.recency)
        #expect(!userTab.isLoaded)
    }

    @Test func closingInitialTabDuringRestorationDoesNotReplaceNewBlank() {
        let store = BrowserStore()
        let initialID = store.selectedTabID
        store.close(store.tabs[0])
        let replacementID = store.selectedTabID
        let saved = restored("saved")
        store.applyRestoredTabs([saved], selectedID: saved.id, initialID: initialID)
        #expect(store.selectedTabID == replacementID)
        #expect(store.tabs.count == 2)
    }

    @Test func optionalWorkWaitsAndCanBeCanceled() async {
        let budget = InteractionBudget(startupDelay: .zero)
        budget.isSearching = true
        let work = Task {
            do {
                try await budget.waitForIdle()
                return true
            } catch { return false }
        }
        await Task.yield()
        work.cancel()
        #expect(await work.value == false)
    }

    @Test func thumbnailsCanLoadWhileSwitcherIsOpen() async throws {
        let budget = InteractionBudget(startupDelay: .zero)
        budget.isSwitching = true
        try await budget.waitForIdle(allowSwitcher: true)
    }
}
