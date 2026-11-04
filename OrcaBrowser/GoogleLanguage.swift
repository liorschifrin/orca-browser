import Foundation

/// Keeps Google in English wherever you are.
///
/// Google picks its language from the network location when nothing else
/// says otherwise, and an incognito tab has no saved choice. Its `hl`
/// address parameter overrides that, so a Google search or home page address
/// without one gets `hl=en` added as the page opens.
enum GoogleLanguage {
    /// The address to open instead of `url`, or nil when it needs no change:
    /// it isn't Google Search or Google's home page, or it already names a language.
    static func englishURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "google.com" || host == "www.google.com",
              ["", "/", "/search"].contains(components.path) else { return nil }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "hl" }) else { return nil }
        items.append(URLQueryItem(name: "hl", value: "en"))
        components.queryItems = items
        return components.url
    }
}
