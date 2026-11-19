import Foundation

/// Links a web view can't load, which belong to another app instead: phone
/// numbers, email, Messages, FaceTime, the App Store and so on. Safari hands
/// these to iOS; a web view would fail with an error.
enum AppLink {
    /// Address schemes the web view loads itself.
    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]
    private static let storeHosts: Set<String> = ["apps.apple.com", "itunes.apple.com"]

    /// The address for iOS to open, or nil when `url` is an ordinary web page
    /// and the tab should load it as usual.
    static func appURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else { return nil }
        if !webSchemes.contains(scheme) { return url }
        // On an iPhone, apps.apple.com answers with a redirect to an
        // `itms-appss:` address. Go straight there.
        guard scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), storeHosts.contains(host) else { return nil }
        // itunes.apple.com also answers web requests (lookup, search) that
        // aren't App Store pages; only its app pages go to the App Store.
        if host == "itunes.apple.com", !url.pathComponents.contains("app") { return nil }
        components.scheme = "itms-appss"
        return components.url
    }
}
