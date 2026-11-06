import Foundation

struct SearchProvider: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var shortcuts: [String]
    var template: String
    var isEnabled = true

    // How the chip is drawn; set from the site this came from.
    var icon = SiteIconChoice.site
    var color = SiteColor.site

    private enum CodingKeys: String, CodingKey { case id, name, shortcuts, template, isEnabled }

    /// Built-ins live in `SearchSite.builtIns`.
    static var builtIns: [SearchProvider] { SearchSite.builtIns.filter { !$0.shortcuts.isEmpty }.map(\.provider) }

    /// Trims surrounding whitespace and folds case for shortcut comparisons.
    nonisolated static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The template host used for local name/domain suggestion matching.
    var domain: String {
        URLComponents(string: template.replacingOccurrences(of: "%s", with: "query"))?.host ?? ""
    }

    /// Returns an editable provider with normalized shortcuts and trimmed fields.
    func normalized() -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.shortcuts = shortcuts.map(Self.normalize)
        copy.template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    /// Returns a settings error for invalid fields or shortcut conflicts, including disabled providers.
    func validationError(among providers: [Self]) -> String? {
        let candidate = normalized()
        guard !candidate.name.isEmpty, candidate.name.count <= 80 else {
            return "Enter a provider name of 1–80 characters."
        }
        guard !candidate.shortcuts.isEmpty else { return "Enter at least one shortcut." }
        var seen = Set<String>()
        for shortcut in candidate.shortcuts {
            guard shortcut.range(of: #"^[a-z0-9][a-z0-9_-]{0,19}$"#, options: .regularExpression) != nil else {
                return "Shortcuts must be 1–20 letters or numbers, with optional hyphens or underscores."
            }
            guard seen.insert(shortcut).inserted else { return "Shortcut ‘\(shortcut)’ is listed more than once." }
            if let conflict = providers.first(where: {
                $0.id != id && $0.shortcuts.contains { Self.normalize($0) == shortcut }
            }) {
                return "Shortcut ‘\(shortcut)’ is already used by \(conflict.name), even if disabled."
            }
        }
        return Self.templateError(candidate.template)
    }

    /// Validates one HTTPS query placeholder outside the authority, with bounded size and valid escapes.
    static func templateError(_ template: String) -> String? {
        guard template.utf8.count <= 2_048 else { return "The template must be at most 2,048 bytes long." }
        let parts = template.components(separatedBy: "%s")
        guard parts.count == 2 else { return "The template must contain exactly one %s placeholder." }
        let sample = parts[0] + "query" + parts[1]
        guard !sample.contains(where: \.isWhitespace),
              let components = URLComponents(string: sample),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.url != nil else {
            return "Enter a valid HTTPS URL without spaces or login details."
        }
        // A query must never be able to change the destination's authority.
        guard let authorityStart = template.range(of: "://")?.upperBound,
              let boundary = template[authorityStart...].firstIndex(where: { "/?#".contains($0) }),
              let placeholder = template.range(of: "%s"), placeholder.lowerBound >= boundary else {
            return "Place %s in the URL path, query, or fragment, after the host."
        }
        // Foundation otherwise repairs malformed percent escapes silently.
        let withoutPlaceholder = template.replacingOccurrences(of: "%s", with: "")
        guard withoutPlaceholder.range(of: #"%(?![0-9A-Fa-f]{2})"#, options: .regularExpression) == nil else {
            return "The template contains an invalid percent escape."
        }
        return nil
    }

    /// Where the site's front page is, for when a chip is entered with no query.
    private static let homePages = [
        "maps": "https://www.google.com/maps",
        "google-images": "https://www.google.com/imghp",
        "ai-mode": "https://www.google.com/?udm=50",
    ]

    /// Resolves the empty-query destination, using special built-in homepages where required.
    var homeURL: URL? {
        if let page = Self.homePages[id] { return URL(string: page) }
        guard var components = URLComponents(string: template.replacingOccurrences(of: "%s", with: "query")),
              components.host?.isEmpty == false else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Encodes the query as UTF-8 URL data and replaces the sole placeholder once.
    func url(for query: String) -> URL? {
        guard Self.templateError(template) == nil else { return nil }
        // Encode UTF-8 bytes, including %, +, &, # and /. Substitute once so a
        // literal %s in the query is data, never a second template instruction.
        let encoded = query.utf8.map { byte -> String in
            switch byte {
            case 65...90, 97...122, 48...57, 45, 46, 95, 126: return String(UnicodeScalar(byte))
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
        let parts = template.components(separatedBy: "%s")
        return URL(string: parts[0] + encoded + parts[1])
    }

    /// Finds an enabled provider by an exact, normalized shortcut.
    static func matchingShortcut(_ shortcut: String, in providers: [Self]) -> Self? {
        let keyword = normalize(shortcut)
        return providers.first { $0.isEnabled && $0.shortcuts.contains { normalize($0) == keyword } }
    }

    /// Only a complete first token followed by whitespace commits automatically.
    static func activation(for input: String, in providers: [Self]) -> (provider: Self, query: String)? {
        let input = input.drop(while: \.isWhitespace)
        guard let separator = input.firstIndex(where: \.isWhitespace),
              let provider = matchingShortcut(String(input[..<separator]), in: providers) else { return nil }
        return (provider, String(input[separator...].drop(while: \.isWhitespace)))
    }

    /// A single offer keeps the clipboard row compact; existing ranking breaks ties.
    static func bestSuggestion(for input: String, in providers: [Self]) -> Self? {
        suggestions(for: input, in: providers).first
    }

    /// Offered only while the first word is still being typed: once a space
    /// follows it, it wasn't a site after all.
    static func suggestions(for input: String, in providers: [Self]) -> [Self] {
        guard !input.drop(while: \.isWhitespace).contains(where: \.isWhitespace) else { return [] }
        let token = normalize(String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(while: { !$0.isWhitespace })))
        guard !token.isEmpty else { return [] }
        /// Orders exact shortcuts before exact names/domains and then prefix matches.
        func rank(_ provider: Self) -> Int? {
            let shortcuts = provider.shortcuts.map(normalize)
            let name = normalize(provider.name)
            let domain = normalize(provider.domain).replacingOccurrences(of: "www.", with: "")
            if shortcuts.contains(token) { return 0 }
            if name == token || domain == token { return 1 }
            if shortcuts.contains(where: { $0.hasPrefix(token) }) || name.hasPrefix(token) || domain.hasPrefix(token) { return 2 }
            return nil
        }
        return providers.enumerated().compactMap { index, provider -> (Self, Int, Int)? in
            guard provider.isEnabled, let rank = rank(provider) else { return nil }
            return (provider, rank, index)
        }.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
    }
}

/// Keep explicit provider selection separate from normal URL resolution.
struct SearchSubmission {
    var text: String
    var url: URL? = nil
    var providerID: String? = nil

    var resolvedURL: URL? { url ?? Destination.url(for: text) }

    /// Opening a site with nothing to search for goes to its front page.
    static func home(of provider: SearchProvider) -> Self? {
        guard let url = provider.homeURL else { return nil }
        return Self(text: "", url: url, providerID: provider.id)
    }

    /// Builds a nonempty provider search, or defers ordinary input to normal URL resolution.
    static func make(text: String, provider: SearchProvider?) -> Self? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        guard let provider else { return Self(text: text) }
        guard let url = provider.url(for: query) else { return nil }
        return Self(text: query, url: url, providerID: provider.id)
    }
}
