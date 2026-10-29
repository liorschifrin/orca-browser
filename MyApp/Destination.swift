import Foundation

/// Turns whatever the user typed into a URL to load.
///
/// - "apple.com", "localhost:3000", "https://x.dev/a" -> opened directly
/// - anything else ("best pizza", "swift tutorial") -> a Google search
///
/// This is a plain function with no UI, which makes it easy to test.
enum Destination {
    static func url(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Spaces mean it's a phrase, never an address.
        if !text.contains(where: \.isWhitespace) {
            let lowercased = text.lowercased()

            // Explicit web address: use as-is. (Other schemes such as
            // "javascript:" are deliberately not treated as addresses.)
            if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
                if let url = URL(string: text), url.host() != nil { return url }
            }
            // Bare address like "apple.com/mac": assume https.
            else if !text.contains("://"),
                    let components = URLComponents(string: "https://" + text),
                    let host = components.host,
                    looksLikeHost(host),
                    let url = components.url {
                return url
            }
        }

        return searchURL(for: text)
    }

    /// True for "localhost", IPv4 addresses, and names like "example.com"
    /// (dot-separated labels ending in a letters-only extension of 2+ chars).
    private static func looksLikeHost(_ host: String) -> Bool {
        let pattern = #"^(localhost|(\d{1,3}\.){3}\d{1,3}|([\p{L}\p{N}]([\p{L}\p{N}-]*[\p{L}\p{N}])?\.)+\p{L}{2,})$"#
        return host.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        // URLComponents handles percent-encoding of spaces, &, etc. for us.
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}
