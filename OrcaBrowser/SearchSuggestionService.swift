import Foundation

/// Remote completions are separate from the local site-shortcut suggestions.
enum SearchSuggestionSource: String, Sendable {
    case google

    static func source(for provider: SearchProvider?) -> Self? {
        guard let provider else { return .google }
        // Only known, unmodified search destinations can send queries to Google.
        guard let site = SearchSite.builtIns.first(where: { $0.id == provider.id }),
              site.template == provider.template,
              ["google", "ai-mode", "google-images"].contains(site.id) else { return nil }
        return .google
    }
}

struct SearchSuggestionRequest: Equatable, Sendable {
    let query: String
    let source: SearchSuggestionSource
    let providerID: String?
    let inEnglish: Bool

    static func make(text: String, provider: SearchProvider?, enabled: Bool,
                     isPresented: Bool, isEditing: Bool, isIncognito: Bool,
                     inEnglish: Bool) -> Self? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, isPresented, isEditing, !isIncognito,
              query.count >= 2, query.count <= 200,
              !query.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }),
              let source = SearchSuggestionSource.source(for: provider) else { return nil }
        // Reuse navigation's address detection, including localhost and IP addresses.
        guard Destination.url(for: query) == Destination.searchURL(for: query),
              !query.contains("://"), !query.contains("@") else { return nil }
        return Self(query: query, source: source, providerID: provider?.id, inEnglish: inEnglish)
    }

    var url: URL {
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        components.queryItems = [URLQueryItem(name: "client", value: "firefox"),
                                 URLQueryItem(name: "q", value: query)]
        if inEnglish { components.queryItems?.append(URLQueryItem(name: "hl", value: "en")) }
        return components.url!
    }
}

actor SearchSuggestionService {
    private let session: URLSession
    private var cache: [SearchSuggestionRequestKey: (date: Date, values: [String])] = [:]

    private struct SearchSuggestionRequestKey: Hashable {
        let query: String
        let source: String
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
        let key = SearchSuggestionRequestKey(query: request.query, source: request.source.rawValue,
                                             inEnglish: request.inEnglish)
        if let entry = cache[key], Date().timeIntervalSince(entry.date) < 60 { return entry.values }
        let (data, response) = try await session.data(from: request.url)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 128_000 else { return [] }
        let values = try Self.parse(data, query: request.query)
        cache = cache.filter { Date().timeIntervalSince($0.value.date) < 60 }
        if cache.count >= 20 { cache.removeAll() }
        cache[key] = (Date(), values)
        return values
    }

    nonisolated static func parse(_ data: Data, query: String) throws -> [String] {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [Any],
              payload.count >= 2, payload[0] as? String == query,
              let suggestions = payload[1] as? [String] else { return [] }
        var seen = Set<String>()
        return Array(suggestions.compactMap { value -> String? in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 200,
                  !value.contains(where: { $0.isNewline }),
                  seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }.prefix(5))
    }
}
