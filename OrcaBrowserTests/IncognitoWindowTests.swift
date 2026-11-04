import Foundation
import Testing
import UIKit
import WebKit
@testable import OrcaBrowser

private final class FakeAuthenticator: IncognitoAuthenticating, @unchecked Sendable {
    var result: String?
    private(set) var asked = 0
    init(result: String? = nil) { self.result = result }
    func authenticate() async -> String? {
        asked += 1
        return result
    }
}

@MainActor
@Suite(.serialized)
struct IncognitoWindowTests {
    private func openPage(in tab: Tab) {
        tab.load(URL(string: "about:blank")!, input: "private")
    }

    @Test func tabsOfTheWindowShareOneSessionAndOtherIncognitoTabsDont() async throws {
        let store = BrowserStore()
        let auth = FakeAuthenticator()
        #expect(store.enterIncognito() == .entered)
        defer { store.closeIncognito() }
        let window = try #require(store.incognitoWindow)
        openPage(in: try #require(store.selectedTab))
        store.open("about:blank")
        #expect(store.tabs.count == 2)
        #expect(store.tabs.allSatisfy { $0.isInIncognitoWindow })
        #expect(store.tabs.allSatisfy { $0.isIncognito })
        for tab in store.tabs {
            #expect(tab.privateDataStore === window.session.dataStore)
            #expect(tab.privateRules === window.session.rules)
        }
        #expect(!window.session.dataStore.isPersistent)

        let alone = Tab(isIncognito: true)
        defer { alone.teardown() }
        #expect(alone.privateDataStore !== window.session.dataStore)
        #expect(alone.privateRules !== window.session.rules)
        #expect(!alone.isInIncognitoWindow)
    }

    @Test func closingAWindowTabLeavesTheSharedStoreForTheOthers() async throws {
        let store = BrowserStore()
        _ = store.enterIncognito()
        defer { store.closeIncognito() }
        let window = try #require(store.incognitoWindow)
        let dataStore = window.session.dataStore
        let cookie = try #require(HTTPCookie(properties: [
            .domain: "incognito-window-test.invalid", .path: "/", .name: "shared", .value: "1"
        ]))
        await dataStore.httpCookieStore.setCookie(cookie)
        let first = try #require(store.selectedTab)
        openPage(in: first)
        store.open("about:blank")
        store.close(first)
        #expect(await dataStore.httpCookieStore.allCookies().contains { $0.name == "shared" })
    }

    @Test func windowTabsNeverJoinTheNormalTabs() async throws {
        let store = BrowserStore()
        let normal = try #require(store.selectedTab)
        _ = store.enterIncognito()
        defer { store.closeIncognito() }
        openPage(in: try #require(store.selectedTab))
        #expect(store.space == .incognito)
        #expect(!store.tabs.contains { $0.id == normal.id })
        store.leaveIncognito()
        #expect(store.space == .normal)
        #expect(store.tabs.map(\.id) == [normal.id])
        #expect(store.selectedTab?.id == normal.id)
        #expect(store.incognitoWindow?.tabs.count == 1)
    }

    @Test func aWindowWithTabsAsksForAChoiceAndContinuingNeedsFaceID() async throws {
        let store = BrowserStore()
        let auth = FakeAuthenticator()
        #expect(store.enterIncognito() == .entered)
        defer { store.closeIncognito() }
        let page = try #require(store.selectedTab)
        openPage(in: page)
        store.leaveIncognito()
        #expect(store.space == .normal)

        // Nothing is asked of Face ID until Continue.
        #expect(store.enterIncognito() == .needsChoice)
        #expect(auth.asked == 0)
        #expect(store.space == .normal)

        auth.result = ""
        #expect(await store.continueIncognito(using: auth) == .denied(nil))
        auth.result = "Face ID didn’t recognize you."
        #expect(await store.continueIncognito(using: auth) == .denied("Face ID didn’t recognize you."))
        #expect(store.space == .normal)

        auth.result = nil
        #expect(await store.continueIncognito(using: auth) == .entered)
        #expect(auth.asked == 3)
        #expect(store.space == .incognito)
        #expect(store.selectedTab?.id == page.id)
    }

    @Test func startingFreshForgetsTheOldTabsAndSession() async throws {
        let store = BrowserStore()
        _ = store.enterIncognito()
        defer { store.closeIncognito() }
        let old = try #require(store.selectedTab)
        openPage(in: old)
        let oldSession = try #require(store.incognitoWindow?.session)
        store.leaveIncognito()
        #expect(store.enterIncognito() == .needsChoice)
        store.startFreshIncognito()
        #expect(store.space == .incognito)
        #expect(old.privateDataStore == nil)
        #expect(store.tabs.count == 1)
        #expect(store.selectedTab?.isBlank == true)
        #expect(store.incognitoWindow?.session !== oldSession)
    }

    @Test func aWindowWithNothingOpenedIsDroppedOnLeaving() async throws {
        let store = BrowserStore()
        let auth = FakeAuthenticator(result: "no")
        #expect(store.enterIncognito() == .entered)
        store.leaveIncognito()
        #expect(store.incognitoWindow == nil)
        #expect(auth.asked == 0)
    }

    @Test func closingTheLastWindowTabClosesTheWindow() async throws {
        let store = BrowserStore()
        _ = store.enterIncognito()
        let tab = try #require(store.selectedTab)
        openPage(in: tab)
        let replacedWithBlank = store.close(tab)
        #expect(!replacedWithBlank)
        #expect(store.space == .normal)
        #expect(store.incognitoWindow == nil)
        #expect(tab.privateDataStore == nil)
    }

    @Test func closeAllIncognitoTabsFromTheWindowReturnsToNormalTabs() async throws {
        let store = BrowserStore()
        let normal = try #require(store.selectedTab)
        _ = store.enterIncognito()
        openPage(in: try #require(store.selectedTab))
        store.open("about:blank")
        store.closeIncognito()
        #expect(store.space == .normal)
        #expect(store.incognitoWindow == nil)
        #expect(store.selectedTab?.id == normal.id)
    }

    @Test func leavingTheWindowUnloadsItsPages() async throws {
        let store = BrowserStore()
        _ = store.enterIncognito()
        defer { store.closeIncognito() }
        let tab = try #require(store.selectedTab)
        openPage(in: tab)
        #expect(tab.isLoaded)
        store.leaveIncognito()
        #expect(!tab.isLoaded)
    }

    @Test func newTabsInTheWindowArePrivateEvenIfAskedOtherwise() async throws {
        let store = BrowserStore()
        _ = store.enterIncognito()
        defer { store.closeIncognito() }
        openPage(in: try #require(store.selectedTab))
        store.open("about:blank", isIncognito: false)
        #expect(store.tabs.count == 2)
        #expect(store.tabs.allSatisfy { $0.isInIncognitoWindow })
    }

    @Test func clipboardIsClearedOnlyIfSomethingWasCopiedInside() throws {
        let pasteboard = UIPasteboard(name: UIPasteboard.Name("orca-incognito-test"), create: true)!
        defer { UIPasteboard.remove(withName: UIPasteboard.Name("orca-incognito-test")) }
        let window = IncognitoWindow()
        defer { window.close() }

        pasteboard.string = "copied before"
        window.didEnter(pasteboard: pasteboard)
        window.didLeave(pasteboard: pasteboard)
        #expect(pasteboard.string == "copied before")

        window.didEnter(pasteboard: pasteboard)
        pasteboard.string = "copied inside"
        window.didLeave(pasteboard: pasteboard)
        #expect(pasteboard.string == nil)
    }
}
