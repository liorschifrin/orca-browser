import XCTest

final class SearchProviderTests: XCTestCase {
    let providers = SearchProvider.builtIns

    func testAllBuiltInsAreValidAndRender() throws {
        for provider in providers {
            XCTAssertNil(provider.validationError(among: providers), provider.name)
            let url = try XCTUnwrap(provider.url(for: "lofi beats"))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertTrue(url.absoluteString.contains("lofi%20beats"))
        }
    }

    func testUTF8EncodingAndLiteralPlaceholder() throws {
        let provider = providers[0]
        let query = "žluťoučký kůň & # 😀 + / %s"
        let url = try XCTUnwrap(provider.url(for: query))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query)
        XCTAssertTrue(url.absoluteString.contains("%26%20%23%20%F0%9F%98%80%20%2B%20%2F%20%25s"))
        XCTAssertFalse(url.absoluteString.contains("%2525s"))
        XCTAssertNil(url.fragment)
    }

    func testPathAndFragmentTemplatesEncodeQueryAsOneValue() throws {
        for template in ["https://example.com/find/%s?fixed=1", "https://example.com/#%s"] {
            let provider = SearchProvider(name: "Example", shortcuts: ["ex"], template: template)
            XCTAssertNil(provider.validationError(among: []))
            XCTAssertTrue(try XCTUnwrap(provider.url(for: "a/b?c#d")).absoluteString.contains("a%2Fb%3Fc%23d"))
        }
    }

    func testShortcutMatchingAndActivation() throws {
        XCTAssertEqual(SearchProvider.matchingShortcut("  WiKi\n", in: providers)?.id, "wikipedia")
        let match = try XCTUnwrap(SearchProvider.activation(for: "  YT  lofi beats  ", in: providers))
        XCTAssertEqual(match.provider.id, "youtube")
        XCTAssertEqual(match.query, "lofi beats  ")
        XCTAssertEqual(SearchProvider.activation(for: "yt ", in: providers)?.query, "")
        for input in ["yt", "ytmusic jazz", "https://yt.com", "yt.com hi", "youtube jazz", "best yt music"] {
            XCTAssertNil(SearchProvider.activation(for: input, in: providers), input)
        }
        var disabled = providers[0]
        disabled.isEnabled = false
        XCTAssertNil(SearchProvider.activation(for: "yt jazz", in: [disabled]))
    }

    func testSuggestionRanking() {
        let exact = SearchProvider(name: "Other", shortcuts: ["you"], template: "https://example.com/?q=%s")
        XCTAssertEqual(SearchProvider.suggestions(for: "YOU", in: providers + [exact]).map(\.id), [exact.id, "youtube"])
        XCTAssertEqual(SearchProvider.suggestions(for: "youtube.com", in: providers).first?.id, "youtube")
        XCTAssertTrue(SearchProvider.suggestions(for: "  ", in: providers).isEmpty)
        XCTAssertEqual(SearchProvider.bestSuggestion(for: "YOU", in: providers + [exact])?.id, exact.id)
        XCTAssertEqual(SearchProvider.bestSuggestion(for: "g", in: providers)?.id, "google-images")
        XCTAssertNil(SearchProvider.bestSuggestion(for: "unmatched", in: providers))
        XCTAssertNil(SearchProvider.bestSuggestion(for: "  ", in: providers))
    }

    func testTemplateValidation() {
        for template in [
            "http://example.com/?q=%s", "https://example.com/", "https://example.com/%s?q=%s",
            "https://%s.example.com/", "https://example.com:%s/", "https://u:%s@example.com/",
            "https:///search?q=%s", "https://user:pass@example.com/?q=%s", "https://example.com/a b?q=%s",
            "https://example.com/%xx?q=%s", "https://example.com/?q=%s&x=" + String(repeating: "a", count: 2048)
        ] {
            XCTAssertNotNil(SearchProvider.templateError(template), template)
        }
        XCTAssertNil(SearchProvider.templateError("https://example.com/?fixed=%20&q=%s"))
    }

    func testShortcutValidationAndNormalization() {
        var candidate = SearchProvider(name: " Example ", shortcuts: [" EX "], template: " https://example.com/?q=%s ")
        XCTAssertNil(candidate.validationError(among: providers))
        XCTAssertEqual(candidate.normalized().shortcuts, ["ex"])
        candidate.shortcuts = [" YT "]
        XCTAssertTrue(candidate.validationError(among: providers)?.contains("YouTube") == true)
        var disabled = providers[0]
        disabled.isEnabled = false
        XCTAssertNotNil(candidate.validationError(among: [disabled]))
        for shortcuts in [[], [""], ["foo bar"], ["example.com"], ["x", " X "], [String(repeating: "a", count: 21)]] {
            candidate.shortcuts = shortcuts
            XCTAssertNotNil(candidate.validationError(among: []))
        }
        candidate = providers[0]
        XCTAssertNil(candidate.validationError(among: providers)) // Editing itself is allowed.
    }

    func testPreferencesRoundTripPreservesEditsAndRemovals() throws {
        var preferences = SearchProviderPreferences()
        var youtube = providers[0]
        youtube.shortcuts = ["video"]
        youtube.isEnabled = false
        preferences.save(youtube)
        preferences.remove(providers[1])
        let custom = SearchProvider(name: "Custom", shortcuts: ["custom"], template: "https://example.com/?q=%s")
        preferences.save(custom)
        let data = try JSONEncoder().encode(preferences)
        let restored = try JSONDecoder().decode(SearchProviderPreferences.self, from: data)
        XCTAssertEqual(restored.providers.first, youtube)
        XCTAssertFalse(restored.providers.contains { $0.id == "wikipedia" })
        XCTAssertTrue(restored.providers.contains(custom))
        XCTAssertTrue(restored.providers.contains { $0.id == "imdb" })
    }

    func testExplicitSubmissionAndNormalBrowsing() throws {
        let submission = try XCTUnwrap(SearchSubmission.make(text: "  lofi beats  ", provider: providers[0]))
        XCTAssertEqual(submission.providerID, "youtube")
        XCTAssertEqual(submission.text, "lofi beats")
        XCTAssertEqual(submission.resolvedURL?.host(), "www.youtube.com")
        XCTAssertNil(SearchSubmission.make(text: "  ", provider: providers[0]))
        for address in ["example.com", "localhost:3000", "https://example.com/path?q=1"] {
            XCTAssertNotEqual(Destination.url(for: address)?.host(), "www.google.com")
        }
        // Shortcut recognition belongs to the field, never the general URL resolver.
        XCTAssertEqual(Destination.url(for: "yt lofi beats")?.host(), "www.google.com")
        XCTAssertEqual(Destination.searchQuery(from: Destination.url(for: "ytmusic jazz")), "ytmusic jazz")
        XCTAssertEqual(SearchSubmission.make(text: "a book", provider: nil)?.resolvedURL, Destination.url(for: "a book"))
    }
}
