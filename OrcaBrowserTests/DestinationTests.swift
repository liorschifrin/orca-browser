import Foundation
import Testing
@testable import OrcaBrowser

struct DestinationTests {
    @Test(arguments: [
        ("apple.com", "https://apple.com"),
        ("apple.com/mac", "https://apple.com/mac"),
        ("https://x.dev/a?b=1", "https://x.dev/a?b=1"),
        ("http://example.org", "http://example.org"),
        ("localhost:3000", "https://localhost:3000"),
        ("192.168.1.1", "https://192.168.1.1"),
    ])
    func addressesOpenDirectly(input: String, expected: String) {
        #expect(Destination.url(for: input)?.absoluteString == expected)
    }

    @Test(arguments: ["best pizza", "swift", "javascript:alert(1)", "file:///etc/passwd"])
    func everythingElseIsAGoogleSearch(input: String) throws {
        let url = try #require(Destination.url(for: input))
        #expect(url.host() == "www.google.com")
        #expect(Destination.searchQuery(from: url) == input)
    }

    @Test func blankInputGoesNowhere() {
        #expect(Destination.url(for: "   ") == nil)
    }

    @Test func searchQueryReadsPlusAsSpace() {
        let url = URL(string: "https://www.google.com/search?q=best+pizza&hl=en")
        #expect(Destination.searchQuery(from: url) == "best pizza")
    }

    @Test func searchQueryIgnoresOtherPages() {
        #expect(Destination.searchQuery(from: URL(string: "https://www.google.com/maps?q=x")) == nil)
        #expect(Destination.searchQuery(from: URL(string: "https://bing.com/search?q=x")) == nil)
        #expect(Destination.searchQuery(from: nil) == nil)
    }
}
