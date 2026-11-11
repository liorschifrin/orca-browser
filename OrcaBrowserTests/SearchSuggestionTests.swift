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

    func testChipUsesItsOwnSuggestionsURL() throws {
        XCTAssertEqual(request()?.template, SearchSite.googleSuggestions)
        let youtube = try XCTUnwrap(SearchProvider.builtIns.first { $0.id == "youtube" })
        let url = try XCTUnwrap(request("lofi", provider: youtube)?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "ds", value: "yt")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "q", value: "lofi")))

        // No suggestions URL, or a bad one: nothing is sent anywhere.
        let chatGPT = try XCTUnwrap(SearchProvider.builtIns.first { $0.id == "chatgpt" })
        XCTAssertNil(request(provider: chatGPT))
        var custom = chatGPT
        custom.suggestionTemplate = "http://example.com/?q=%s"
        XCTAssertNil(request(provider: custom))
        custom.suggestionTemplate = "https://example.com/complete?q=%s"
        XCTAssertEqual(request("tea time", provider: custom)?.url?.absoluteString,
                       "https://example.com/complete?q=tea%20time")
    }

    func testOnlyGoogleGetsTheLanguage() throws {
        XCTAssertTrue(try XCTUnwrap(request()?.url?.query()).contains("hl=en"))
        let bing = try XCTUnwrap(SearchProvider.builtIns.first { $0.id == "bing" })
        XCTAssertFalse(try XCTUnwrap(request(provider: bing)?.url?.query()).contains("hl=en"))
    }

    func testSavedBuiltInsFromBeforeSuggestionsGetThem() throws {
        let old = Data(#"{"id":"youtube","name":"YouTube","template":"https://www.youtube.com/results?search_query=%s","shortcuts":["yt"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SearchSite.self, from: old).suggestionTemplate,
                       SearchSite.builtInSuggestions["youtube"])
        let cleared = Data(#"{"id":"youtube","name":"YouTube","template":"https://www.youtube.com/results?search_query=%s","suggestionTemplate":""}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SearchSite.self, from: cleared).suggestionTemplate, "")
        let custom = Data(#"{"id":"mine","name":"Mine","template":"https://example.com/?q=%s"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SearchSite.self, from: custom).suggestionTemplate, "")
    }

    func testPastedLineBreaksOfEveryKindBecomeSpaces() {
        XCTAssertEqual(ChipTextField.oneLine("a\rb"), "a b")
        XCTAssertEqual(ChipTextField.oneLine("a \r\n b\u{2028}c\n"), "a b c")
        XCTAssertEqual(ChipTextField.oneLine(" plain "), " plain ")
    }

    func testSuggestionsURLMustSendTheQuery() {
        XCTAssertNotNil(SearchProvider.suggestionTemplateError("https://example.com/suggest#q=%s"))
        XCTAssertNil(SearchProvider.suggestionTemplateError("https://example.com/suggest?q=%s#top"))
        var custom = SearchProvider.builtIns[0]
        custom.suggestionTemplate = "https://example.com/suggest#q=%s"
        XCTAssertNil(request(provider: custom))
    }

    func testBadSuggestionsURLIsNotSaved() {
        var site = SearchSite(name: "Mine", template: "https://example.com/?q=%s", shortcuts: ["mine"])
        site.suggestionTemplate = "https://example.com/complete"
        XCTAssertNotNil(site.validationError(among: []))
        site.suggestionTemplate = "https://example.com/complete?q=%s"
        XCTAssertNil(site.validationError(among: []))
    }

    func testRequestEncodesUnicodeAndQueryCharacters() throws {
        let query = "café & tea + #"
        let url = try XCTUnwrap(request(query)?.url as URL?)
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

    func testParsesAmazonAndIMDb() throws {
        let amazon = Data(#"{"alias":"aps","prefix":"usb c","suggestions":[{"value":"usb c cable"},{"value":"usb c hub"}]}"#.utf8)
        XCTAssertEqual(try SearchSuggestionService.parse(amazon, query: "usb c"), ["usb c cable", "usb c hub"])
        XCTAssertEqual(try SearchSuggestionService.parse(amazon, query: "usb"), [])
        let imdb = Data(#"{"d":[{"l":"Dune","id":"tt1"},{"l":"Dune: Part Two","id":"tt2"}],"q":"dune"}"#.utf8)
        XCTAssertEqual(try SearchSuggestionService.parse(imdb, query: "dune"), ["Dune", "Dune: Part Two"])
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
