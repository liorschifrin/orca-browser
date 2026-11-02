import UIKit

/// What we remember about one tab between launches. The heavier things (the
/// card's picture, the icon, the web view's history) live in files beside it.
struct SavedTab: Codable {
    var id: UUID
    var url: URL?
    var title: String?
    var recency: Int
    var searchText: String? = nil
    var peek: SavedPeek? = nil
}

struct SavedPeek: Codable {
    var url: URL
    var currentURL: URL?
    var title: String?
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
///     Tabs/<id>.peek.state  the held link's web view state, when open
///     Tabs/<id>.peek.jpg    the held link's page picture
///     Tabs/<id>.jpg         the card's picture
///     Tabs/<id>.png         the site's icon
///
/// Blank tabs aren't saved; there's nothing in them to keep.
/// Closed-all tabs go to a second folder, ClosedTabs, laid out the same way.
@MainActor
enum TabPersistence {
    private static var directory: URL = {
        let base = URL.applicationSupportDirectory.appending(path: "Tabs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Revisions already on disk, so unchanged pictures aren't re-encoded.
    private static var writtenSnapshots: [UUID: Int] = [:]
    private static var writtenPeekSnapshots: [UUID: Int] = [:]
    private static var writtenFavicons: [UUID: Int] = [:]
    /// History blobs already on disk, so unchanged ones aren't rewritten.
    private static var writtenStates: [UUID: Data] = [:]
    private static var writtenPeekStates: [UUID: Data] = [:]

    /// Encoding pictures and writing files happens here, in order, so saving
    /// never holds up the main thread (and so never drops frames).
    private static let queue = DispatchQueue(label: "TabPersistence", qos: .utility)

    /// One piece of disk work, prepared on the main thread and run on `queue`.
    nonisolated private enum Write: @unchecked Sendable {
        case data(Data, URL)
        case jpeg(UIImage, URL)
        case png(UIImage, URL)
        case remove(URL)
    }

    private static func file(_ id: UUID, _ ext: String) -> URL {
        directory.appending(path: "\(id.uuidString).\(ext)")
    }

    private static func savedTab(_ tab: Tab) -> SavedTab {
        SavedTab(
            id: tab.id, url: tab.url, title: tab.title, recency: tab.recency,
            searchText: tab.searchText,
            peek: tab.peek.map { SavedPeek(url: $0.url, currentURL: $0.tab.url, title: $0.tab.title) }
        )
    }

    private static func restoredTab(_ saved: SavedTab) -> Tab {
        Tab(
            restoring: saved,
            snapshot: image(file(saved.id, "jpg")),
            favicon: image(file(saved.id, "png")),
            interactionState: try? Data(contentsOf: file(saved.id, "state")),
            peekInteractionState: try? Data(contentsOf: file(saved.id, "peek.state")),
            peekSnapshot: image(file(saved.id, "peek.jpg"))
        )
    }

    static func save(tabs: [Tab], selectedID: Tab.ID) {
        let saved = tabs.filter { !$0.isBlank }
        var writes: [Write] = []

        let session = SavedSession(tabs: saved.map(savedTab), selectedID: selectedID)
        if let data = try? JSONEncoder().encode(session) {
            writes.append(.data(data, directory.appending(path: "session.json")))
        }

        for tab in saved {
            if let state = tab.interactionStateForSaving, writtenStates[tab.id] != state {
                writes.append(.data(state, file(tab.id, "state")))
                writtenStates[tab.id] = state
            }
            if let state = tab.peek?.tab.interactionStateForSaving {
                if writtenPeekStates[tab.id] != state {
                    writes.append(.data(state, file(tab.id, "peek.state")))
                    writtenPeekStates[tab.id] = state
                }
            } else {
                writes.append(.remove(file(tab.id, "peek.state")))
                writtenPeekStates[tab.id] = nil
            }
            if let peekTab = tab.peek?.tab, let image = peekTab.snapshot {
                if writtenPeekSnapshots[tab.id] != peekTab.snapshotRevision {
                    writes.append(.jpeg(image, file(tab.id, "peek.jpg")))
                    writtenPeekSnapshots[tab.id] = peekTab.snapshotRevision
                }
            } else {
                writes.append(.remove(file(tab.id, "peek.jpg")))
                writtenPeekSnapshots[tab.id] = nil
            }
            if let image = tab.snapshot, writtenSnapshots[tab.id] != tab.snapshotRevision {
                writes.append(.jpeg(image, file(tab.id, "jpg")))
                writtenSnapshots[tab.id] = tab.snapshotRevision
            }
            if let icon = tab.favicon, writtenFavicons[tab.id] != tab.faviconRevision {
                writes.append(.png(icon, file(tab.id, "png")))
                writtenFavicons[tab.id] = tab.faviconRevision
            }
        }
        let keep = Set(saved.map(\.id))
        // Forget closed tabs; their files are deleted below.
        writtenSnapshots = writtenSnapshots.filter { keep.contains($0.key) }
        writtenPeekSnapshots = writtenPeekSnapshots.filter { keep.contains($0.key) }
        writtenFavicons = writtenFavicons.filter { keep.contains($0.key) }
        writtenStates = writtenStates.filter { keep.contains($0.key) }
        writtenPeekStates = writtenPeekStates.filter { keep.contains($0.key) }

        // iOS may suspend the app right after it leaves the foreground; ask
        // for a little time so the files get written.
        let application = UIApplication.shared
        let backgroundTask = application.beginBackgroundTask(withName: "Save tabs")
        let directory = directory
        queue.async {
            perform(writes)
            removeFiles(in: directory, except: keep)
            DispatchQueue.main.async { application.endBackgroundTask(backgroundTask) }
        }
    }

    nonisolated private static func perform(_ writes: [Write]) {
        for write in writes {
            switch write {
            case .data(let data, let url):
                try? data.write(to: url, options: .atomic)
            case .jpeg(let image, let url):
                try? image.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)
            case .png(let image, let url):
                try? image.pngData()?.write(to: url, options: .atomic)
            case .remove(let url):
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Returns the saved tabs (none loaded yet) and the current tab's id, or
    /// nil if there is nothing saved.
    static func load() -> (tabs: [Tab], selectedID: UUID?)? {
        guard let data = try? Data(contentsOf: directory.appending(path: "session.json")),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data),
              !session.tabs.isEmpty
        else { return nil }

        return (session.tabs.map(restoredTab), session.selectedID)
    }

    // MARK: - Closed tabs

    // "Close All" puts tabs here. It's the same set of files, in a folder of
    // its own, with `session.json` holding just the list of tabs. Nothing about
    // them stays in memory; the next launch finds them too.
    private static var closedDirectory: URL = {
        let base = URL.applicationSupportDirectory.appending(path: "ClosedTabs", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static var closedListFile: URL {
        closedDirectory.appending(path: "session.json")
    }

    private static func closedTabs() -> [SavedTab] {
        guard let data = try? Data(contentsOf: closedListFile) else { return [] }
        return (try? JSONDecoder().decode([SavedTab].self, from: data)) ?? []
    }

    static func closedTabCount() -> Int {
        closedTabs().count
    }

    /// Moves `tabs` out to the closed folder, after any already there. Throws,
    /// before any file moves, if the list can't be written.
    static func stashClosed(_ tabs: [Tab], selectedID: Tab.ID) throws {
        let closing = tabs.filter { !$0.isBlank }
        // Bring the live files up to date, then move them rather than
        // encoding every picture again.
        save(tabs: tabs, selectedID: selectedID)

        let list = closedTabs() + closing.map(savedTab)
        try JSONEncoder().encode(list).write(to: closedListFile, options: .atomic)

        let ids = Set(closing.map(\.id))
        moveFiles(of: ids, from: directory, to: closedDirectory)
        for id in ids {
            writtenSnapshots[id] = nil
            writtenPeekSnapshots[id] = nil
            writtenFavicons[id] = nil
        }
    }

    /// Brings the closed tabs back, oldest-used first (none loaded yet). Their
    /// files move back to the live folder, but the closed list stays until the
    /// caller has saved them there; then call `clearClosed()`.
    static func unstashClosed() -> [Tab] {
        let list = closedTabs()
        moveFiles(of: Set(list.map(\.id)), from: closedDirectory, to: directory)

        return list.sorted { $0.recency < $1.recency }.map { saved in
            let tab = restoredTab(saved)
            // The pictures were just read from the files that are now in place,
            // so the next save needn't encode them again.
            if tab.snapshot != nil { writtenSnapshots[tab.id] = tab.snapshotRevision }
            if let peekTab = tab.peek?.tab, peekTab.snapshot != nil {
                writtenPeekSnapshots[tab.id] = peekTab.snapshotRevision
            }
            if tab.favicon != nil { writtenFavicons[tab.id] = tab.faviconRevision }
            return tab
        }
    }

    static func clearClosed() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: closedDirectory.path(percentEncoded: false))) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: closedDirectory.appending(path: name))
        }
    }

    private static func moveFiles(of ids: Set<UUID>, from source: URL, to destination: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path(percentEncoded: false))) ?? []
        for name in names {
            let stem = String(name.split(separator: ".", maxSplits: 1).first ?? "")
            guard let id = UUID(uuidString: stem), ids.contains(id) else { continue }
            let target = destination.appending(path: name)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.moveItem(at: source.appending(path: name), to: target)
        }
    }

    /// Reads the whole file up front. `UIImage(contentsOfFile:)` memory-maps it
    /// instead, which breaks ("mmapped file changed") when a later save
    /// replaces the file while the picture is still in use.
    private static func image(_ url: URL) -> UIImage? {
        (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
    }

    /// Deletes files belonging to tabs that no longer exist.
    nonisolated private static func removeFiles(in directory: URL, except keep: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name != "session.json" {
            let stem = String(name.split(separator: ".", maxSplits: 1).first ?? "")
            if let id = UUID(uuidString: stem), !keep.contains(id) {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
    }
}
