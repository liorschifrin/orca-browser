import Foundation
import Testing
@testable import MyApp

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
}
