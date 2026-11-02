import Foundation
import Testing
@testable import MyApp

@MainActor
struct AutoArchiveTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func tab(lastOpenedAt: Date? = nil) -> Tab {
        Tab(restoring: SavedTab(
            id: UUID(), url: URL(string: "https://example.com"), title: "Example", recency: 1,
            lastOpenedAt: lastOpenedAt
        ), hasSnapshot: false, favicon: nil)
    }

    @Test func archivesAtTheInactivityThreshold() {
        let old = tab(lastOpenedAt: now.addingTimeInterval(-7 * 24 * 60 * 60))
        #expect(BrowserStore.shouldAutoArchive(old, selectedID: UUID(), days: 7, now: now))
        #expect(!BrowserStore.shouldAutoArchive(old, selectedID: UUID(), days: 7, now: now.addingTimeInterval(-1)))
    }

    @Test func keepsCurrentAndRecentlyOpenedTabs() {
        let old = tab(lastOpenedAt: now.addingTimeInterval(-30 * 24 * 60 * 60))
        let recent = tab(lastOpenedAt: now.addingTimeInterval(-60))
        #expect(!BrowserStore.shouldAutoArchive(old, selectedID: old.id, days: 7, now: now))
        #expect(!BrowserStore.shouldAutoArchive(recent, selectedID: UUID(), days: 7, now: now))
        #expect(!BrowserStore.shouldAutoArchive(old, selectedID: UUID(), days: 0, now: now))
    }

    @Test func keepsBlankTabs() {
        let blank = Tab()
        blank.lastOpenedAt = now.addingTimeInterval(-30 * 24 * 60 * 60)
        #expect(!BrowserStore.shouldAutoArchive(blank, selectedID: UUID(), days: 7, now: now))
        blank.teardown()
    }

    @Test func memoryPolicyTimestampDoesNotResetInactivity() {
        let old = tab(lastOpenedAt: now.addingTimeInterval(-30 * 24 * 60 * 60))
        old.lastViewed = now
        #expect(BrowserStore.shouldAutoArchive(old, selectedID: UUID(), days: 7, now: now))
    }

    @Test func lastOpenedDateSurvivesEncoding() throws {
        let saved = SavedTab(id: UUID(), url: URL(string: "https://example.com"), title: nil,
                             recency: 1, lastOpenedAt: now)
        let decoded = try JSONDecoder().decode(SavedTab.self, from: JSONEncoder().encode(saved))
        let restored = Tab(restoring: decoded, hasSnapshot: false, favicon: nil)
        #expect(restored.lastOpenedAt == now)
    }

    @Test func olderSessionsStartWithAFreshInactivityPeriod() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","url":"https://example.com","recency":1}
        """.utf8)
        let saved = try JSONDecoder().decode(SavedTab.self, from: data)
        #expect(saved.lastOpenedAt == nil)
        let before = Date.now
        let restored = Tab(restoring: saved, hasSnapshot: false, favicon: nil)
        #expect(restored.lastOpenedAt >= before)
        #expect(!BrowserStore.shouldAutoArchive(restored, selectedID: UUID(), days: 1, now: .now))
    }
}
