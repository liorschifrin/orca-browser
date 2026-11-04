import Foundation
import Testing
@testable import OrcaBrowser

@MainActor
struct PictureInPictureReturnTests {
    @Test func returningToTheVideoSwitchesToItsTab() {
        let store = BrowserStore()
        let first = store.tabs.first!
        store.openInBackground(URL(string: "https://example.com")!)
        let other = store.tabs.last!
        // The first tab played the video, and we've since moved on.
        store.select(other)
        #expect(store.selectedTabID == other.id)

        first.onPictureInPictureReturn?()
        #expect(store.selectedTabID == first.id)
    }

    @Test func returningToTheTabAlreadyShowingDoesNothing() {
        let store = BrowserStore()
        let current = store.selectedTab!
        current.onPictureInPictureReturn?()
        #expect(store.selectedTabID == current.id)
    }
}
