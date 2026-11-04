import Foundation
import Testing
@testable import OrcaBrowser

struct ContentBlockerTests {
    @Test func everyFilterHasItsOwnIdentifier() {
        let identifiers = ContentBlocker.filters.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test func cookieNoticesFilterIsListed() {
        let filter = ContentBlocker.filters.first { $0.id == 18 }
        #expect(filter?.category == .cookieBanners)
        #expect(filter?.url?.absoluteString == "https://filters.adtidy.org/ios/filters/18_optimized.txt")
        #expect(ContentBlocker.shared.category(ofList: "orcabrowser.adguard.18") == .cookieBanners)
    }

    @Test func builtInBannerRulesAreValidAndNamedAfterTheirContent() throws {
        let rules = try #require(JSONSerialization.jsonObject(with: Data(CookieBanners.hideRulesJSON.utf8)) as? [[String: Any]])
        #expect(!rules.isEmpty)
        let builtIn = ContentBlocker.filters.filter { if case .builtIn = $0.source { true } else { false } }
        #expect(builtIn.allSatisfy { $0.url == nil && $0.identifier.hasPrefix(ContentBlocker.Filter.builtInPrefix) })
        #expect(builtIn.first?.identifier != ContentBlocker.Filter(id: 1001, category: .cookieBanners, name: "x", source: .builtIn(json: "[]")).identifier)
    }

    @MainActor
    @Test func aRetriedBlockedRequestIsCountedOnce() {
        let tab = Tab()
        defer { tab.teardown() }
        let ad = URL(string: "https://ads.example/config.json")!
        for _ in 0..<1000 { tab.countBlocked(.ads, url: ad) }
        tab.countBlocked(.ads, url: URL(string: "https://ads.example/other.js")!)
        tab.countBlocked(.trackers, url: URL(string: "https://track.example/p.gif")!)
        #expect(tab.adsBlocked == 2)
        #expect(tab.trackersBlocked == 1)
        tab.pageDidCommit()
        tab.countBlocked(.ads, url: ad)
        #expect(tab.adsBlocked == 1)
    }

    @Test func cookieBannerSettingIsOnByDefaultAndSurvivesRelaunch() throws {
        let suite = "ContentBlockerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppSettings(defaults: defaults).blockCookieBanners)
        AppSettings(defaults: defaults).blockCookieBanners = false
        #expect(!AppSettings(defaults: defaults).blockCookieBanners)
    }
}
