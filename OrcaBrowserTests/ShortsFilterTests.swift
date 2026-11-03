import Foundation
import Testing
@testable import OrcaBrowser

struct ShortsFilterTests {
    @Test(arguments: [
        "https://www.youtube.com/shorts/abc123",
        "https://m.youtube.com/shorts/abc123",
        "https://youtube.com/shorts/abc123?feature=share",
    ])
    func shortsBecomeTheWatchPage(address: String) {
        let url = ShortsFilter.watchURL(forShorts: URL(string: address)!)
        #expect(url?.absoluteString == "https://www.youtube.com/watch?v=abc123")
    }

    @Test(arguments: [
        "https://www.youtube.com/watch?v=abc123",
        "https://www.youtube.com/shorts",
        "https://www.youtube.com/shorts/",
        "https://example.com/shorts/abc123",
        "https://notyoutube.com/shorts/abc123",
    ])
    func otherAddressesAreLeftAlone(address: String) {
        #expect(ShortsFilter.watchURL(forShorts: URL(string: address)!) == nil)
    }

    @Test func openingShortsDefaultsToOffUnlessHidingWasOn() {
        let fresh = UserDefaults(suiteName: "ShortsFilterTests-\(UUID())")!
        #expect(AppSettings(defaults: fresh).opensShortsAsVideos == false)

        let hiding = UserDefaults(suiteName: "ShortsFilterTests-\(UUID())")!
        hiding.set(true, forKey: "hideShorts")
        #expect(AppSettings(defaults: hiding).opensShortsAsVideos == true)

        hiding.set(false, forKey: "opensShortsAsVideos")
        #expect(AppSettings(defaults: hiding).opensShortsAsVideos == false)
    }
}
