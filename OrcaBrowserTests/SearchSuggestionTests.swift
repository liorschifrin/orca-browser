import XCTest
@testable import OrcaBrowser

@MainActor
final class SearchSuggestionTests: XCTestCase {
    private func request(_ text: String = "coffee", provider: SearchProvider? = nil,
                         enabled: Bool = true, presented: Bool = true,
                         editing: Bool = true, incognito: Bool = false) -> SearchSuggestionRequest? {
        SearchSuggestionRequest.make(text: text, provider: provider, enabled: enabled,
                                     isPresented: presented, isEditing: editing,
                                     isIncognito: incognito, inEnglish: true)
    }

    func testPrivacyAndLifecycleGates() {
        XCTAssertNotNil(request())
        XCTAssertNil(request(enabled: false))
        XCTAssertNil(request(presented: false))
        XCTAssertNil(request(editing: false))
        XCTAssertNil(request(incognito: true))
        for text in ["", "a", "example.com", "localhost:3000", "127.0.0.1", "https://example.com/private", "me@example.com", "coffee\nshop"] {
            XCTAssertNil(request(text), text)
        }
    }

    func testOnlySupportedUnmodifiedProvidersUseGoogle() throws {
        for id in ["google", "ai-mode", "google-images"] {
            let provider = try XCTUnwrap(SearchProvider.builtIns.first { $0.id == id })
            XCTAssertEqual(request(provider: provider)?.providerID, id)
        }
        let youtube = try XCTUnwrap(SearchProvider.builtIns.first { $0.id == "youtube" })
        XCTAssertNil(request(provider: youtube))
        var google = try XCTUnwrap(SearchProvider.builtIns.first { $0.id == "google" })
        google.template = "https://example.com/?q=%s"
        XCTAssertNil(request(provider: google))
    }

    func testRequestEncodesUnicodeAndQueryCharacters() throws {
        let query = "café & tea + #"
        let url = try XCTUnwrap(request(query)?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "suggestqueries.google.com")
        XCTAssertEqual(components.queryItems?.first { $0.name == "q" }?.value, query)
        XCTAssertNil(components.fragment)
    }

    func testParsingBoundsDeduplicatesAndRejectsMismatchedQueries() throws {
        let data = Data(#"["coffee",[" coffee shop ","COFFEE SHOP","","coffee beans","coffee grinder","coffee cake","coffee machine","coffee cup"],[],{}]"#.utf8)
        XCTAssertEqual(try SearchSuggestionService.parse(data, query: "coffee"),
                       ["coffee shop", "coffee beans", "coffee grinder", "coffee cake", "coffee machine"])
        XCTAssertEqual(try SearchSuggestionService.parse(data, query: "tea"), [])
        XCTAssertEqual(try SearchSuggestionService.parse(Data(#"["coffee",{}]"#.utf8), query: "coffee"), [])
        XCTAssertThrowsError(try SearchSuggestionService.parse(Data("invalid".utf8), query: "coffee"))
    }

    func testSettingPersistsAndDefaultsOn() throws {
        let name = "SearchSuggestionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.searchSuggestions)
        settings.searchSuggestions = false
        XCTAssertFalse(AppSettings(defaults: defaults).searchSuggestions)
    }
}
