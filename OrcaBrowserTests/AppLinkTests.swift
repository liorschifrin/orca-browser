import Foundation
import Testing
@testable import OrcaBrowser

struct AppLinkTests {
    @Test(arguments: [
        ("https://apps.apple.com/app/id6753721487", "itms-appss://apps.apple.com/app/id6753721487"),
        (
            "https://apps.apple.com/app/apple-store/id6811986917?pt=129455565&ct=yt-ep99&mt=8",
            "itms-appss://apps.apple.com/app/apple-store/id6811986917?pt=129455565&ct=yt-ep99&mt=8"
        ),
        ("https://APPS.apple.com/us/app/x/id1", "itms-appss://APPS.apple.com/us/app/x/id1"),
        ("http://itunes.apple.com/app/id1", "itms-appss://itunes.apple.com/app/id1"),
        ("itms-appss://apps.apple.com/app/id1", "itms-appss://apps.apple.com/app/id1"),
        ("itms-apps://itunes.apple.com/app/id1", "itms-apps://itunes.apple.com/app/id1"),
        ("tel:+15551234567", "tel:+15551234567"),
        ("mailto:someone@example.com?subject=Hi", "mailto:someone@example.com?subject=Hi"),
        ("sms:+15551234567", "sms:+15551234567"),
        ("facetime:someone@example.com", "facetime:someone@example.com"),
        ("youtube://watch?v=5C_GbASnAZc", "youtube://watch?v=5C_GbASnAZc"),
    ])
    func opensInOtherApp(address: String, expected: String) {
        #expect(AppLink.appURL(for: URL(string: address)!)?.absoluteString == expected)
    }

    @Test(arguments: [
        "https://www.apple.com/app-store/",
        "https://apps.apple.com.evil.example/app/id1",
        "https://notapps.apple.com/app/id1",
        "https://m.youtube.com/watch?v=5C_GbASnAZc",
        "about:blank",
        "data:text/html,hi",
        "blob:https://example.com/0f1e2d",
        "javascript:void(0)",
    ])
    func leavesOtherAddressesAlone(address: String) {
        #expect(AppLink.appURL(for: URL(string: address)!) == nil)
    }
}
