import Foundation
import Testing
@testable import OrcaBrowser

struct ContentBlockerTests {
    @Test func everyFilterHasItsOwnIdentifier() {
        let identifiers = ContentBlocker.filters.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test func cookieNoticesFilterIsListed() {
        let filter = ContentBlocker.filters.first { $0.category == .cookieBanners }
        #expect(filter?.id == 18)
        #expect(filter?.url.absoluteString == "https://filters.adtidy.org/ios/filters/18_optimized.txt")
        #expect(ContentBlocker.shared.category(ofList: "orcabrowser.adguard.18") == .cookieBanners)
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
