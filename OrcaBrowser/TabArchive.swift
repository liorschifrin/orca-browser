import Foundation

nonisolated struct ArchivedTab: Codable, Identifiable, Sendable {
    var tab: SavedTab
    var archivedAt: Date

    var id: UUID { tab.id }
    var title: String { tab.title.flatMap { $0.isEmpty ? nil : $0 } ?? tab.url?.host() ?? "Untitled Tab" }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || title.localizedStandardContains(query)
            || (tab.url?.absoluteString.localizedStandardContains(query) ?? false)
    }
}

nonisolated struct TabArchive: Sendable {
    static let shared = TabArchive(directory: URL.applicationSupportDirectory.appending(path: "ArchivedTabs", directoryHint: .isDirectory))
    let directory: URL

    private var listFile: URL { directory.appending(path: "archive.json") }

    func load() throws -> [ArchivedTab] {
        guard FileManager.default.fileExists(atPath: listFile.path(percentEncoded: false)) else { return [] }
        return try JSONDecoder().decode([ArchivedTab].self, from: Data(contentsOf: listFile))
    }

    func save(_ entries: [ArchivedTab]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: listFile, options: .atomic)
    }
}
