import Foundation
import Testing
import SwiftData
import WebKit
@testable import OrcaBrowser

@MainActor
@Suite(.serialized)
struct IncognitoTests {
    @Test func websiteStorageIsTemporaryAndIsolated() async throws {
        let first = Tab(isIncognito: true)
        let second = Tab(isIncognito: true)
        let regular = Tab()
        defer { first.teardown(); second.teardown(); regular.teardown() }
        // Tabs create WebKit only once they navigate.
        first.load(URL(string: "about:blank")!, input: "private search")
        regular.load(URL(string: "about:blank")!, input: "ordinary")

        let firstStore = try #require(first.privateDataStore)
        let secondStore = try #require(second.privateDataStore)
        #expect(!firstStore.isPersistent)
        #expect(firstStore !== secondStore)
        #expect(regular.webView?.configuration.websiteDataStore.isPersistent == true)
        #expect(first.webView?.configuration.websiteDataStore === firstStore)

        let cookie = try #require(HTTPCookie(properties: [
            .domain: "incognito-test.invalid", .path: "/", .name: "private", .value: "secret"
        ]))
        await firstStore.httpCookieStore.setCookie(cookie)
        #expect(await firstStore.httpCookieStore.allCookies().contains { $0.name == "private" })
        #expect(await secondStore.httpCookieStore.allCookies().isEmpty)

        first.unload()
        first.activate()
        #expect(first.webView?.configuration.websiteDataStore === firstStore)
        #expect(first.interactionStateForSaving == nil)

        first.openPeek(URL(string: "https://incognito-test.invalid")!)
        let preview = try #require(first.peek?.tab)
        #expect(preview.isIncognito)
        first.teardown()
        #expect(first.webView == nil)
        #expect(first.privateDataStore == nil)
        #expect(first.url == nil)
        #expect(first.searchText.isEmpty)
        #expect(first.snapshot == nil)
        #expect(preview.privateDataStore == nil)
        #expect(second.privateDataStore === secondStore)
    }

    @Test func privateNavigationDoesNotWriteHistory() throws {
        let privateTab = Tab(isIncognito: true)
        let regularTab = Tab()
        let page = HistoryProbeWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let address = page.probeURL.absoluteString
        let context = HistoryStore.shared.container.mainContext
        let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.urlString == address })
        defer {
            privateTab.teardown()
            regularTab.teardown()
            for entry in (try? context.fetch(descriptor)) ?? [] { context.delete(entry) }
            HistoryStore.shared.flush()
        }
        privateTab.mirror(page)
        HistoryStore.flushIfNeeded()
        #expect(try context.fetch(descriptor).isEmpty)
        regularTab.mirror(page)
        HistoryStore.flushIfNeeded()
        #expect(try context.fetch(descriptor).count == 1)
    }

    @Test func privateTabsNeverEnterSessionOrClosedTabArchive() async throws {
        let regular = Tab()
        let secret = Tab(isIncognito: true)
        defer {
            regular.teardown()
            secret.teardown()
            TabPersistence.clearClosed()
            TabPersistence.save(tabs: [], selectedID: regular.id)
            _ = TabPersistence.unstashClosed()
        }
        regular.load(URL(string: "about:blank")!, input: "ordinary")
        secret.load(URL(string: "about:blank")!, input: "secret")
        TabPersistence.clearClosed()
        TabPersistence.save(tabs: [regular, secret], selectedID: secret.id)
        // Restoring synchronizes with the persistence queue, even for an empty archive.
        #expect(TabPersistence.unstashClosed().isEmpty)
        let session = await TabPersistence.loadStartup()
        #expect(session.tabs.map(\.id) == [regular.id])
        #expect(session.selectedID == regular.id)

        try TabPersistence.stashClosed([regular, secret], selectedID: secret.id)
        #expect(TabPersistence.closedTabCount() == 1)
        let restored = TabPersistence.unstashClosed()
        defer { for tab in restored { tab.teardown() } }
        #expect(restored.map(\.id) == [regular.id])
        let folder = URL.applicationSupportDirectory.appending(path: "Tabs")
        let filenames = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!filenames.contains { $0.hasPrefix(secret.id.uuidString) })
    }

    @Test func blankPrivateTabsCanBeClosedWithoutBeingArchived() async {
        let store = BrowserStore()
        await store.restoreSession()
        for tab in Array(store.tabs) { store.close(tab) }
        store.newIncognitoTab()
        let privateTab = store.selectedTab!
        #expect(privateTab.isIncognito)
        #expect(store.tabs.contains { $0.id == privateTab.id })
        let archivedCount = store.closedTabCount
        store.closeAll()
        #expect(store.tabs.count == 1)
        #expect(store.selectedTab?.isIncognito == false)
        #expect(privateTab.privateDataStore == nil)
        #expect(store.closedTabCount == archivedCount)
        store.save()
        for tab in store.tabs { tab.teardown() }
    }
}

/// Supplies a deterministic navigation event without contacting a website.
@MainActor
private final class HistoryProbeWebView: WKWebView {
    let probeURL = URL(string: "https://incognito-test.invalid/\(UUID().uuidString)")!
    override var url: URL? { probeURL }
    override var title: String? { "Private page" }
}
