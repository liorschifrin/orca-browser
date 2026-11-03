import Foundation
import Testing
@testable import MyApp

@MainActor
struct TabArchiveTests {
    private func entry(title: String? = "Example") -> ArchivedTab {
        ArchivedTab(tab: SavedTab(
            id: UUID(), url: URL(string: "https://example.com/article"), title: title, recency: 3,
            peek: SavedPeek(url: URL(string: "https://example.com/link")!, currentURL: nil, title: "Link"),
            lastOpenedAt: Date(timeIntervalSince1970: 1_800_000_000)
        ), archivedAt: Date(timeIntervalSince1970: 1_800_100_000))
    }

    @Test func archiveStoragePersistsTabMetadataAndRemovals() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = TabArchive(directory: directory)
        #expect(try storage.load().isEmpty)
        let first = entry()
        let second = entry(title: "Another page")
        try storage.save([first, second])
        let loaded = try storage.load()
        #expect(loaded.map(\.id) == [first.id, second.id])
        #expect(loaded.first?.tab.lastOpenedAt == first.tab.lastOpenedAt)
        #expect(loaded.first?.archivedAt == first.archivedAt)
        #expect(loaded.first?.tab.peek?.url == first.tab.peek?.url)
        try storage.save(loaded.filter { $0.id != first.id })
        #expect(try storage.load().map(\.id) == [second.id])
    }

    @Test func searchingMatchesTitleAndURL() {
        let archived = entry()
        #expect(archived.matches("  "))
        #expect(archived.matches("EXAMPLE"))
        #expect(archived.matches("article"))
        #expect(!archived.matches("unrelated"))
        #expect(entry(title: "").title == "example.com")
        #expect(entry(title: nil).title == "example.com")
    }

    @Test func invalidArchiveIsNotSilentlyTreatedAsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = TabArchive(directory: directory)
        try storage.save([entry()])
        try Data("invalid json".utf8).write(to: directory.appending(path: "archive.json"))
        #expect(throws: DecodingError.self) { try storage.load() }
    }
}
