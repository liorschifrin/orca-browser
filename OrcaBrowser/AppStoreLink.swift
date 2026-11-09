import Foundation

/// Sends App Store links to the App Store app, like Safari.
///
/// On an iPhone, apps.apple.com answers a page load with a redirect to an
/// `itms-appss:` address, which a web view can't load: the tab would end on
/// an error with nothing to go back to. So these links are caught before they
/// load and handed to the system instead.
enum AppStoreLink {
    private static let schemes: Set<String> = ["itms-apps", "itms-appss"]
    private static let hosts: Set<String> = ["apps.apple.com", "itunes.apple.com"]

    /// The address for the App Store app to open, or nil when `url` isn't an
    /// App Store link and the tab should load it as usual.
    static func storeURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return nil }
        if schemes.contains(scheme) { return url }
        guard scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), hosts.contains(host) else { return nil }
        components.scheme = "itms-appss"
        return components.url
    }
}
