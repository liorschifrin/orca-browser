import Foundation
import Testing
@testable import OrcaBrowser

struct AppStoreLinkTests {
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
    ])
    func opensInAppStore(address: String, expected: String) {
        #expect(AppStoreLink.storeURL(for: URL(string: address)!)?.absoluteString == expected)
    }

    @Test(arguments: [
        "https://www.apple.com/app-store/",
        "https://apps.apple.com.evil.example/app/id1",
        "https://notapps.apple.com/app/id1",
        "https://m.youtube.com/watch?v=5C_GbASnAZc",
        "about:blank",
    ])
    func leavesOtherAddressesAlone(address: String) {
        #expect(AppStoreLink.storeURL(for: URL(string: address)!) == nil)
    }
}
