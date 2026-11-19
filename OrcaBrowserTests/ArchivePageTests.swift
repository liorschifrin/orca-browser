import Foundation
import Testing
@testable import OrcaBrowser

struct ArchivePageTests {
    private let story = URL(string: "https://www.example.com/2026/11/08/a-story")!

    @Test func opensTheNewestCopyWithoutTrackingOrFragment() {
        let page = URL(string: "https://www.example.com/story?id=4&utm_source=x&fbclid=y#comments")!
        #expect(ArchivePage.url(for: page)?.absoluteString == "https://archive.ph/newest/https://www.example.com/story?id=4")
        let tracked = URL(string: "https://example.com/story?utm_medium=email")!
        #expect(ArchivePage.url(for: tracked)?.absoluteString == "https://archive.ph/newest/https://example.com/story")
    }

    @Test func skipsPagesThatCantBeArchived() {
        #expect(ArchivePage.url(for: URL(string: "about:blank")!) == nil)
        #expect(ArchivePage.url(for: URL(string: "https://archive.ph/abc12")!) == nil)
        #expect(ArchivePage.url(for: URL(string: "https://www.archive.today/abc12")!) == nil)
    }

    @Test func articlesAreRecognizedByTheirMarks() {
        #expect(ArchivePage.isArticle(story, signals: .init(ogType: "article")))
        #expect(ArchivePage.isArticle(story, signals: .init(schemaTypes: ["WebPage", "NewsArticle"])))
        #expect(ArchivePage.isArticle(story, signals: .init(hasPublishedTime: true)))
        #expect(ArchivePage.isArticle(story, signals: .init(articleWords: 800)))
    }

    @Test func otherPagesAreNotArticles() {
        #expect(!ArchivePage.isArticle(story, signals: .init(ogType: "website", articleWords: 40)))
        #expect(!ArchivePage.isArticle(URL(string: "https://www.example.com/")!, signals: .init(ogType: "article")))
        #expect(!ArchivePage.isArticle(URL(string: "https://archive.ph/abc12")!, signals: .init(ogType: "article")))
    }
}
