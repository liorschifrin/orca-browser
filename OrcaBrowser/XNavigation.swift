import Foundation

/// X redirects embedded iPhone browsers to x-safari-https://redirect.x.com.
/// Identifying as Safari on X keeps its public web pages in this browser.
enum XNavigation {
    private static let hosts: Set<String> = [
        "x.com", "www.x.com", "m.x.com", "mobile.x.com", "redirect.x.com",
        "twitter.com", "www.twitter.com", "m.twitter.com", "mobile.twitter.com",
    ]

    static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && hosts.contains(url.host()?.lowercased() ?? "")
    }

    /// Only the observed Safari handoff format, on known X hosts. Preserve the
    /// post path and query; redirect.x.com itself just redirects back to X.
    static func webURL(forSafariURL url: URL) -> URL? {
        guard url.scheme?.lowercased() == "x-safari-https",
              hosts.contains(url.host()?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        if parts.host?.lowercased() == "redirect.x.com" { parts.host = "x.com" }
        return parts.url
    }

    /// Public pages link posts through m.x.com with an App Store launch flag.
    /// Use the same post on the web, including media paths and reply anchors.
    static func webURL(forPromotedLink url: URL) -> URL? {
        guard isWebURL(url), url.user == nil, url.password == nil, url.port == nil,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if ["m.x.com", "mobile.x.com", "redirect.x.com", "m.twitter.com", "mobile.twitter.com"]
            .contains(parts.host?.lowercased() ?? "") {
            parts.host = "x.com"
            parts.scheme = "https"
        }
        if let query = parts.percentEncodedQuery {
            let items = query.components(separatedBy: "&")
            let remaining = items.filter {
                $0.components(separatedBy: "=").first?.removingPercentEncoding != "launch_app_store"
            }
            if remaining.count != items.count {
                parts.percentEncodedQuery = remaining.isEmpty ? nil : remaining.joined(separator: "&")
            }
        }
        guard let web = parts.url, web != url else { return nil }
        return web
    }

    static func safariUserAgent(from webKitAgent: String) -> String {
        if webKitAgent.contains(" Safari/") { return webKitAgent }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return webKitAgent + " Version/\(version.majorVersion).\(version.minorVersion) Safari/604.1"
    }

    static func retryURL(failed: URL?, requested: URL?) -> URL? {
        if let failed, let web = webURL(forSafariURL: failed) { return web }
        if let failed, ["http", "https"].contains(failed.scheme?.lowercased() ?? "") {
            return webURL(forPromotedLink: failed) ?? failed
        }
        guard let requested, ["http", "https"].contains(requested.scheme?.lowercased() ?? "") else { return nil }
        return requested
    }
}
