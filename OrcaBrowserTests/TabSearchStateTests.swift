import Foundation
import Testing
import WebKit
@testable import OrcaBrowser

@MainActor
struct TabSearchStateTests {
    @Test(arguments: [false, true]) func googleNavigationReplacesStaleProvider(useMirror: Bool) throws {
        let tab = Tab()
        defer { tab.teardown() }
        tab.searchProviderID = "youtube"
        tab.searchText = "old query"
        let url = try #require(URL(string: "https://www.google.com/search?q=new+query"))
        if useMirror {
            tab.mirror(SearchNavigationWebView(url: url))
        } else {
            tab.load(url)
        }
        #expect(tab.searchProviderID == nil)
        #expect(tab.searchText == "new query")
    }

    @Test(arguments: ["google", "google-images", "ai-mode"]) func matchingGoogleProviderKeepsChipAndRefreshesQuery(id: String) throws {
        let tab = Tab()
        defer { tab.teardown() }
        tab.searchProviderID = id
        tab.searchText = "old query"
        let provider = try #require(SearchProvider.builtIns.first { $0.id == id })
        let url = try #require(provider.url(for: "žluťoučký & emoji 🐳"))
        tab.refreshSearchState(for: url)
        #expect(tab.searchProviderID == id)
        #expect(tab.searchText == "žluťoučký & emoji 🐳")
        tab.refreshSearchState(for: try #require(URL(string: "https://example.com/")))
        #expect(tab.searchProviderID == id)
    }

    @Test func imagesRedirectKeepsProvider() throws {
        let tab = Tab()
        defer { tab.teardown() }
        tab.searchProviderID = "google-images"
        tab.searchText = "cats"
        tab.refreshSearchState(for: try #require(URL(string: "https://www.google.com/search?tbm=isch&q=dogs&source=hp")))
        #expect(tab.searchProviderID == "google-images")
        #expect(tab.searchText == "dogs")
    }

    @Test func ordinaryGoogleSearchClearsImagesMode() throws {
        let tab = Tab()
        defer { tab.teardown() }
        tab.searchProviderID = "google-images"
        tab.searchText = "cats"
        tab.refreshSearchState(for: try #require(Destination.searchURL(for: "dogs")))
        #expect(tab.searchProviderID == nil)
        #expect(tab.searchText == "dogs")
    }
}

@MainActor
private final class SearchNavigationWebView: WKWebView {
    let navigationURL: URL
    init(url: URL) {
        navigationURL = url
        super.init(frame: .zero, configuration: WKWebViewConfiguration())
    }
    required init?(coder: NSCoder) { fatalError() }
    override var url: URL? { navigationURL }
}
