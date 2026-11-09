import Foundation

/// Completions from the search site: Google with no chip, else the chip's
/// own suggestions URL. Separate from the local site-shortcut suggestions.
struct SearchSuggestionRequest: Equatable, Sendable {
    let query: String
    /// The suggestions URL, with one `%s`.
    let template: String
    let providerID: String?
    let inEnglish: Bool

    static func make(text: String, provider: SearchProvider?, enabled: Bool,
                     isPresented: Bool, isEditing: Bool, isIncognito: Bool,
                     inEnglish: Bool) -> Self? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = provider?.suggestionTemplate ?? SearchSite.googleSuggestions
        guard enabled, isPresented, isEditing, !isIncognito,
              query.count >= 2, query.count <= 200,
              !query.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }),
              !template.isEmpty, SearchProvider.templateError(template) == nil else { return nil }
        // Reuse navigation's address detection, including localhost and IP addresses.
        guard Destination.url(for: query) == Destination.searchURL(for: query),
              !query.contains("://"), !query.contains("@") else { return nil }
        return Self(query: query, template: template, providerID: provider?.id, inEnglish: inEnglish)
    }

    var url: URL? {
        guard let url = SearchProvider.url(filling: template, with: query) else { return nil }
        // Google answers in the language Google Search is set to open in.
        guard inEnglish, url.host() == "suggestqueries.google.com",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "hl", value: "en")]
        return components.url
    }
}

actor SearchSuggestionService {
    private let session: URLSession
    private var cache: [SearchSuggestionRequestKey: (date: Date, values: [String])] = [:]

    private struct SearchSuggestionRequestKey: Hashable {
        let query: String
        let template: String
        let inEnglish: Bool
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
    }

    func clearCache() { cache.removeAll() }

    func suggestions(for request: SearchSuggestionRequest) async throws -> [String] {
        let key = SearchSuggestionRequestKey(query: request.query, template: request.template,
                                             inEnglish: request.inEnglish)
        if let entry = cache[key], Date().timeIntervalSince(entry.date) < 60 { return entry.values }
        guard let url = request.url else { return [] }
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 128_000 else { return [] }
        let values = try Self.parse(data, query: request.query)
        cache = cache.filter { Date().timeIntervalSince($0.value.date) < 60 }
        if cache.count >= 20 { cache.removeAll() }
        cache[key] = (Date(), values)
        return values
    }

    /// Reads OpenSearch JSON (`["query", ["suggestion", …]]`), Amazon's
    /// `{"prefix", "suggestions": [{"value"}]}` and IMDb's `{"d": [{"l"}]}`.
    /// Answers for a different query than the one asked are ignored.
    nonisolated static func parse(_ data: Data, query: String) throws -> [String] {
        let payload = try JSONSerialization.jsonObject(with: data)
        let values: [String]
        if let array = payload as? [Any] {
            guard array.count >= 2, array[0] as? String == query,
                  let suggestions = array[1] as? [String] else { return [] }
            values = suggestions
        } else if let object = payload as? [String: Any], let items = object["suggestions"] as? [[String: Any]] {
            guard object["prefix"] as? String == query else { return [] }
            values = items.compactMap { $0["value"] as? String }
        } else if let object = payload as? [String: Any], let items = object["d"] as? [[String: Any]] {
            values = items.compactMap { $0["l"] as? String }
        } else {
            return []
        }
        var seen = Set<String>()
        return Array(values.compactMap { value -> String? in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 200,
                  !value.contains(where: { $0.isNewline }),
                  seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }.prefix(5))
    }
}
