import Foundation
import Testing
@testable import OrcaBrowser

struct GoogleLanguageTests {
    @Test(arguments: [
        ("https://www.google.com/search?q=bananas", "https://www.google.com/search?q=bananas&hl=en"),
        ("https://google.com/search?q=a%20b&sei=x", "https://google.com/search?q=a%20b&sei=x&hl=en"),
        ("https://www.google.com/", "https://www.google.com/?hl=en"),
        ("https://www.google.com", "https://www.google.com?hl=en"),
        ("https://www.google.com/search?q=c%2B%2B", "https://www.google.com/search?q=c%2B%2B&hl=en"),
    ])
    func addsEnglish(address: String, expected: String) {
        #expect(GoogleLanguage.englishURL(for: URL(string: address)!)?.absoluteString == expected)
    }

    @Test(arguments: [
        "https://www.google.com/search?q=bananas&hl=cs",
        "https://www.google.com/search?hl=en&q=bananas",
        "https://www.google.com/maps",
        "https://maps.google.com/",
        "https://www.google.com/accounts/login",
        "https://notgoogle.com/search?q=a",
        "https://www.google.com.evil.example/search?q=a",
        "http://www.google.com/search?q=a",
        "https://example.com/search?q=a",
    ])
    func leavesOtherAddressesAlone(address: String) {
        #expect(GoogleLanguage.englishURL(for: URL(string: address)!) == nil)
    }
}
