import Foundation
import Testing
@testable import OrcaBrowser

struct XNavigationTests {
    @Test(arguments: [
        ("x-safari-https://redirect.x.com/NASA/status/123?ct=rw-null&s=20#replies",
         "https://x.com/NASA/status/123?ct=rw-null&s=20#replies"),
        ("x-safari-https://x.com/NASA", "https://x.com/NASA"),
    ])
    func safariHandoffKeepsWebDestination(address: String, expected: String) {
        #expect(XNavigation.webURL(forSafariURL: URL(string: address)!)?.absoluteString == expected)
    }

    @Test(arguments: [
        "x-safari-https://evil.example/NASA/status/123",
        "x-safari-https://x.com.evil.example/NASA",
        "x-safari-https://user@redirect.x.com/NASA",
        "x-safari-https://redirect.x.com:123/NASA",
        "twitter://status?id=123",
        "https://x.com/NASA/status/123",
    ])
    func unrelatedOrMalformedLinksAreNotRewritten(address: String) {
        #expect(XNavigation.webURL(forSafariURL: URL(string: address)!) == nil)
    }

    @Test(arguments: [
        ("https://m.x.com/NASA/status/123?launch_app_store=true&ct=engagement_reply#replies",
         "https://x.com/NASA/status/123?ct=engagement_reply#replies"),
        ("https://mobile.twitter.com/NASA/status/123/photo/1?launch_app_store=true",
         "https://x.com/NASA/status/123/photo/1"),
        ("https://x.com/NASA/status/123?s=20&launch_app_store=true", "https://x.com/NASA/status/123?s=20"),
        ("https://m.x.com/search?q=c%2B%2B&launch_app_store=true&src=a%26b",
         "https://x.com/search?q=c%2B%2B&src=a%26b"),
    ])
    func promotedPostsStayOnWeb(address: String, expected: String) {
        #expect(XNavigation.webURL(forPromotedLink: URL(string: address)!)?.absoluteString == expected)
    }

    @Test(arguments: ["https://example.com/?launch_app_store=true", "https://x.com/NASA/status/123?s=20"])
    func ordinaryLinksAreNotRewritten(address: String) {
        #expect(XNavigation.webURL(forPromotedLink: URL(string: address)!) == nil)
    }

    @Test(arguments: ["https://x.com/NASA", "https://mobile.twitter.com/NASA", "https://redirect.x.com/"])
    func compatibilityOnlyOnKnownWebHosts(address: String) {
        #expect(XNavigation.isWebURL(URL(string: address)!))
    }

    @Test(arguments: ["https://example.com/", "https://x.com.evil.example/", "https://notx.com/", "twitter://x.com/"])
    func otherSitesKeepTheirBrowserIdentity(address: String) {
        #expect(!XNavigation.isWebURL(URL(string: address)!))
    }

    @Test func compatibilityKeepsWebKitDeviceAndEngineDetails() {
        let original = "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        let safari = XNavigation.safariUserAgent(from: original)
        #expect(safari.hasPrefix(original))
        #expect(safari.contains(" Version/"))
        #expect(safari.hasSuffix(" Safari/604.1"))
        #expect(XNavigation.safariUserAgent(from: safari) == safari)
    }

    @MainActor @Test func failedHandoffRetriesThePostInsteadOfTheAppScheme() {
        let tab = Tab()
        defer { tab.teardown() }
        tab.pageWillNavigate(to: URL(string: "https://www.google.com/search?q=NASA")!)
        tab.pageDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "x-safari-https://redirect.x.com/NASA/status/123?ct=rw-null")!]))
        #expect(tab.loadError?.failedURL?.absoluteString == "https://x.com/NASA/status/123?ct=rw-null")
        #expect(tab.loadError?.symbol == "exclamationmark.triangle")
    }

    @MainActor @Test func unsupportedRedirectRetainsLastWebDestination() {
        let tab = Tab()
        defer { tab.teardown() }
        let destination = URL(string: "https://x.com/NASA/status/123")!
        tab.pageWillNavigate(to: destination)
        tab.pageWillNavigate(to: URL(string: "unknown-app://post/123")!)
        tab.pageDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnsupportedURL,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "unknown-app://post/123")!]))
        #expect(tab.loadError?.failedURL == destination)
    }

    @MainActor @Test func ordinaryNetworkFailureRetriesItsOwnURL() {
        let tab = Tab()
        defer { tab.teardown() }
        let destination = URL(string: "https://example.com/offline")!
        tab.pageWillNavigate(to: URL(string: "https://x.com/NASA")!)
        tab.pageDidFail(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSURLErrorFailingURLErrorKey: destination]))
        #expect(tab.loadError?.failedURL == destination)
        #expect(tab.loadError?.symbol == "wifi.exclamationmark")
    }
}
