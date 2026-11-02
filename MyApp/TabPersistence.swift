import UIKit

/// What we remember about one tab between launches. The heavier things (the
/// card's picture, the icon, the web view's history) live in files beside it.
struct SavedTab: Codable {
    var id: UUID
    var url: URL?
    var title: String?
    var recency: Int
    var searchText: String? = nil
}

private struct SavedSession: Codable {
    var tabs: [SavedTab]
    var selectedID: UUID?
}

/// Saves open tabs to disk and brings them back at launch.
///
/// Everything goes in one folder inside Application Support (private to the
/// app, backed up, never cleared by iOS):
///
///     Tabs/session.json     the list of tabs and which one was current
///     Tabs/<id>.state       the web view's back/forward list + scroll position
///     Tabs/<id>.jpg         the card's picture
///     Tabs/<id>.png         the site's icon
///
/// Blank tabs aren't saved; there's nothing in them to keep.
@MainActor
enum TabPersistence {
    private static var directory: URL = {
        let base = URL.applicationSupportDirectory.appending(path: "Tabs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Revisions already on disk, so unchanged pictures aren't re-encoded.
    private static var writtenSnapshots: [UUID: Int] = [:]
    private static var writtenFavicons: [UUID: Int] = [:]

    private static func file(_ id: UUID, _ ext: String) -> URL {
        directory.appending(path: "\(id.uuidString).\(ext)")
    }

    static func save(tabs: [Tab], selectedID: Tab.ID) {
        let saved = tabs.filter { !$0.isBlank }

        let session = SavedSession(
            tabs: saved.map { SavedTab(id: $0.id, url: $0.url, title: $0.title, recency: $0.recency, searchText: $0.searchText) },
            selectedID: selectedID
        )
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: directory.appending(path: "session.json"), options: .atomic)
        }

        for tab in saved {
            if let state = tab.interactionStateForSaving {
                try? state.write(to: file(tab.id, "state"), options: .atomic)
            }
            if let image = tab.snapshot, writtenSnapshots[tab.id] != tab.snapshotRevision {
                try? image.jpegData(compressionQuality: 0.8)?.write(to: file(tab.id, "jpg"), options: .atomic)
                writtenSnapshots[tab.id] = tab.snapshotRevision
            }
            if let icon = tab.favicon, writtenFavicons[tab.id] != tab.faviconRevision {
                try? icon.pngData()?.write(to: file(tab.id, "png"), options: .atomic)
                writtenFavicons[tab.id] = tab.faviconRevision
            }
        }

        removeFiles(except: Set(saved.map(\.id)))
    }

    /// Returns the saved tabs (none loaded yet) and the current tab's id, or
    /// nil if there is nothing saved.
    static func load() -> (tabs: [Tab], selectedID: UUID?)? {
        guard let data = try? Data(contentsOf: directory.appending(path: "session.json")),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              !session.tabs.isEmpty
        else { return nil }

        let tabs = session.tabs.map { saved in
            Tab(
                restoring: saved,
                snapshot: image(file(saved.id, "jpg")),
                favicon: image(file(saved.id, "png")),
                interactionState: try? Data(contentsOf: file(saved.id, "state"))
            )
        }
        return (tabs, session.selectedID)
    }

    /// Reads the whole file up front. `UIImage(contentsOfFile:)` memory-maps it
    /// instead, which breaks ("mmapped file changed") when a later save
    /// replaces the file while the picture is still in use.
    private static func image(_ url: URL) -> UIImage? {
        (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
    }

    /// Deletes files belonging to tabs that no longer exist.
    private static func removeFiles(except keep: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name != "session.json" {
            let stem = (name as NSString).deletingPathExtension
            if let id = UUID(uuidString: stem), !keep.contains(id) {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
                writtenSnapshots[id] = nil
                writtenFavicons[id] = nil
            }
        }
    }
}
