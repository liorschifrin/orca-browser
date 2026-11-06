import UIKit

/// What we remember about one tab between launches. The heavier things (the
/// card's picture, the icon, the web view's history) live in files beside it.
nonisolated struct SavedTab: Codable, Sendable {
    var id: UUID
    var url: URL?
    var title: String?
    var recency: Int
    var searchText: String? = nil
    var searchProviderID: String? = nil
    var peek: SavedPeek? = nil
    var lastOpenedAt: Date? = nil
}

nonisolated struct SavedPeek: Codable, Sendable {
    var url: URL
    var currentURL: URL?
    var title: String?
}

nonisolated private struct SavedSession: Codable, Sendable {
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
    nonisolated private static let directory = URL.applicationSupportDirectory.appending(path: "Tabs", directoryHint: .isDirectory)

    nonisolated struct Startup: Sendable {
        var tabs: [SavedTab] = []
        var selectedID: UUID?
        var files: Set<String> = []
        var closedCount = 0
        var archived: [ArchivedTab] = []
    }

    static func loadStartup() async -> Startup {
        await Task.detached(priority: .userInitiated) {
            var result = Startup()
            if let data = try? Data(contentsOf: directory.appending(path: "session.json")),
               let session = try? JSONDecoder().decode(SavedSession.self, from: data) {
                result.tabs = session.tabs
                result.selectedID = session.selectedID
            }
            result.files = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [])
            let support = URL.applicationSupportDirectory
            if let data = try? Data(contentsOf: support.appending(path: "ClosedTabs/session.json")) {
                result.closedCount = (try? JSONDecoder().decode([SavedTab].self, from: data).count) ?? 0
            }
            result.archived = (try? TabArchive.shared.load()) ?? []
            return result
        }.value
    }

    static func restoreRecord(_ saved: SavedTab, files: Set<String>) -> Tab {
        let hasSnapshot = files.contains("\(saved.id.uuidString).jpg")
        let peekHasSnapshot = files.contains("\(saved.id.uuidString).peek.jpg")
        let tab = Tab(restoring: saved, hasSnapshot: hasSnapshot, favicon: nil, peekHasSnapshot: peekHasSnapshot)
        if hasSnapshot { writtenSnapshots[tab.id] = tab.snapshotRevision }
        if let peek = tab.peek?.tab, peekHasSnapshot { writtenPeekSnapshots[tab.id] = peek.snapshotRevision }
        return tab
    }

    /// Revisions already on disk, so unchanged pictures aren't re-encoded.
    private static var writtenSnapshots: [UUID: Int] = [:]
    private static var writtenPeekSnapshots: [UUID: Int] = [:]
    private static var writtenFavicons: [UUID: Int] = [:]
    /// History blobs already on disk, so unchanged ones aren't rewritten.
    private static var writtenStates: [UUID: Data] = [:]
    private static var writtenPeekStates: [UUID: Data] = [:]
    /// Pictures handed to `queue` that aren't on disk yet. Readers check here
    /// first, so they never get the file's older contents.
    private static var unwrittenPictures: [URL: UIImage] = [:]

    /// Encoding pictures and writing files happens here, in order, so saving
    /// never holds up the main thread (and so never drops frames).
    private static let queue = DispatchQueue(label: "TabPersistence", qos: .utility)

    /// One piece of disk work, prepared on the main thread and run on `queue`.
    nonisolated private enum Write: @unchecked Sendable {
        case data(Data, URL)
        case session(SavedSession, URL)
        case jpeg(UIImage, URL)
        case png(UIImage, URL)
    }

    private static func file(_ id: UUID, _ ext: String) -> URL {
        directory.appending(path: "\(id.uuidString).\(ext)")
    }

    /// The picture file for a tab (a held link's page is filed under the tab
    /// it belongs to).
    static func snapshotFile(for tab: Tab) -> URL {
        file(tab.fileOwner.id, tab.fileOwner.isPeek ? "peek.jpg" : "jpg")
    }

    private static func stateFile(for tab: Tab) -> URL {
        file(tab.fileOwner.id, tab.fileOwner.isPeek ? "peek.state" : "state")
    }

    private static func savedTab(_ tab: Tab) -> SavedTab {
        SavedTab(
            id: tab.id, url: tab.url, title: tab.title, recency: tab.recency,
            searchText: tab.searchText,
            searchProviderID: tab.searchProviderID,
            peek: tab.peek.map { SavedPeek(url: $0.url, currentURL: $0.tab.url, title: $0.tab.title) },
            lastOpenedAt: tab.lastOpenedAt
        )
    }

    /// A tab from disk. Only what the tab list needs is read now; the picture
    /// and history are read when the tab is shown.
    private static func restoredTab(_ saved: SavedTab) -> Tab {
        let fileManager = FileManager.default
        let hasSnapshot = fileManager.fileExists(atPath: file(saved.id, "jpg").path(percentEncoded: false))
        let peekHasSnapshot = fileManager.fileExists(atPath: file(saved.id, "peek.jpg").path(percentEncoded: false))
        let tab = Tab(
            restoring: saved,
            hasSnapshot: hasSnapshot,
            favicon: image(file(saved.id, "png")),
            peekHasSnapshot: peekHasSnapshot
        )
        // These files are already on disk, so the next save needn't write
        // them again.
        if hasSnapshot { writtenSnapshots[tab.id] = tab.snapshotRevision }
        if let peekTab = tab.peek?.tab, peekHasSnapshot {
            writtenPeekSnapshots[tab.id] = peekTab.snapshotRevision
        }
        if tab.favicon != nil { writtenFavicons[tab.id] = tab.faviconRevision }
        return tab
    }

    /// A tab's picture, read back from disk (or from a save still under way).
    static func loadSnapshot(for tab: Tab) -> UIImage? {
        guard !tab.isIncognito else { return nil }
        let url = snapshotFile(for: tab)
        return unwrittenPictures[url] ?? image(url)
    }

    /// Memory-only lookup: thumbnail callers must never synchronously read a JPEG.
    static func pendingSnapshot(for tab: Tab) -> UIImage? {
        unwrittenPictures[snapshotFile(for: tab)]
    }

    static func readInteractionState(for tab: Tab) async -> Data? {
        guard !tab.isIncognito else { return nil }
        let file = stateFile(for: tab)
        let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
        guard !Task.isCancelled else { return nil }
        if tab.fileOwner.isPeek { writtenPeekStates[tab.fileOwner.id] = data }
        else { writtenStates[tab.fileOwner.id] = data }
        return data
    }

    static func save(tabs: [Tab], selectedID: Tab.ID) {
        let saved = tabs.filter { !$0.isBlank && !$0.isIncognito }
        var writes: [Write] = []

        // The selected tab may be a private one, which is never saved.
        let session = SavedSession(tabs: saved.map(savedTab), selectedID: saved.first(where: { $0.id == selectedID })?.id
            ?? saved.max(by: { $0.recency < $1.recency })?.id)
        writes.append(.session(session, directory.appending(path: "session.json")))

        for tab in saved {
            if let state = tab.interactionStateForSaving, writtenStates[tab.id] != state {
                writes.append(.data(state, file(tab.id, "state")))
                writtenStates[tab.id] = state
            }
            if let image = tab.snapshot, writtenSnapshots[tab.id] != tab.snapshotRevision {
                writes.append(.jpeg(image, file(tab.id, "jpg")))
                writtenSnapshots[tab.id] = tab.snapshotRevision
            }
            if let icon = tab.favicon, writtenFavicons[tab.id] != tab.faviconRevision {
                writes.append(.png(icon, file(tab.id, "png")))
                writtenFavicons[tab.id] = tab.faviconRevision
            }
            if let peekTab = tab.peek?.tab {
                if let state = peekTab.interactionStateForSaving, writtenPeekStates[tab.id] != state {
                    writes.append(.data(state, file(tab.id, "peek.state")))
                    writtenPeekStates[tab.id] = state
                }
                if let image = peekTab.snapshot, writtenPeekSnapshots[tab.id] != peekTab.snapshotRevision {
                    writes.append(.jpeg(image, file(tab.id, "peek.jpg")))
                    writtenPeekSnapshots[tab.id] = peekTab.snapshotRevision
                }
            } else {
                // Its files are deleted below.
                writtenPeekStates[tab.id] = nil
                writtenPeekSnapshots[tab.id] = nil
            }

            // Pictures of tabs nobody is looking at needn't stay in memory
            // once they're saved. (Each one is ~5 MB decoded.)
            if !tab.isLoaded, tab.id != selectedID {
                if writtenSnapshots[tab.id] == tab.snapshotRevision { tab.releaseSnapshot() }
                if let peekTab = tab.peek?.tab, !peekTab.isLoaded,
                   writtenPeekSnapshots[tab.id] == peekTab.snapshotRevision {
                    peekTab.releaseSnapshot()
                }
            }
        }
        let keep = Set(saved.map(\.id))
        let peeks = Set(saved.filter { $0.peek != nil }.map(\.id))
        // Forget closed tabs; their files are deleted below.
        writtenSnapshots = writtenSnapshots.filter { keep.contains($0.key) }
        writtenPeekSnapshots = writtenPeekSnapshots.filter { keep.contains($0.key) }
        writtenFavicons = writtenFavicons.filter { keep.contains($0.key) }
        writtenStates = writtenStates.filter { keep.contains($0.key) }
        writtenPeekStates = writtenPeekStates.filter { keep.contains($0.key) }

        var pictures: [(URL, UIImage)] = []
        for case .jpeg(let image, let url) in writes {
            unwrittenPictures[url] = image
            pictures.append((url, image))
        }

        // iOS may suspend the app right after it leaves the foreground; ask
        // for a little time so the files get written.
        let application = UIApplication.shared
        let backgroundTask = application.beginBackgroundTask(withName: "Save tabs")
        let directory = directory
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            perform(writes)
            removeFiles(in: directory, except: keep, peeks: peeks)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // On disk now, unless a newer picture took its place.
                    for (url, image) in pictures where unwrittenPictures[url] === image {
                        unwrittenPictures[url] = nil
                    }
                    application.endBackgroundTask(backgroundTask)
                }
            }
        }
    }

    nonisolated private static func perform(_ writes: [Write]) {
        for write in writes {
            switch write {
            case .session(let session, let url):
                try? JSONEncoder().encode(session).write(to: url, options: .atomic)
            case .data(let data, let url):
                try? data.write(to: url, options: .atomic)
            case .jpeg(let image, let url):
                try? image.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)
            case .png(let image, let url):
                try? image.pngData()?.write(to: url, options: .atomic)
            }
        }
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
        let closing = tabs.filter { !$0.isBlank && !$0.isIncognito }
        guard !closing.isEmpty else { return }
        // Bring the live files up to date, then move them rather than
        // encoding every picture again.
        save(tabs: tabs, selectedID: selectedID)

        let list = closedTabs() + closing.map(savedTab)
        try JSONEncoder().encode(list).write(to: closedListFile, options: .atomic)

        let ids = Set(closing.map(\.id))
        // On the save queue, so the files move only once they're written.
        let (source, destination) = (directory, closedDirectory)
        queue.async { moveFiles(of: ids, from: source, to: destination) }
        writtenSnapshots = writtenSnapshots.filter { !ids.contains($0.key) }
        writtenPeekSnapshots = writtenPeekSnapshots.filter { !ids.contains($0.key) }
        writtenFavicons = writtenFavicons.filter { !ids.contains($0.key) }
        writtenStates = writtenStates.filter { !ids.contains($0.key) }
        writtenPeekStates = writtenPeekStates.filter { !ids.contains($0.key) }
    }

    /// Brings the closed tabs back, oldest-used first (none loaded yet). Their
    /// files move back to the live folder, but the closed list stays until the
    /// caller has saved them there; then call `clearClosed()`.
    static func unstashClosed() -> [Tab] {
        let list = closedTabs()
        let ids = Set(list.map(\.id))
        let (source, destination) = (closedDirectory, directory)
        // Waits for any save still writing them before moving them back.
        queue.sync { moveFiles(of: ids, from: source, to: destination) }

        return list.sorted { $0.recency < $1.recency }.map(restoredTab)
    }

    static func clearClosed() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: closedDirectory.path(percentEncoded: false))) ?? []
        for name in names {
            try? FileManager.default.removeItem(at: closedDirectory.appending(path: name))
        }
    }

    static func archive(_ archiving: [Tab], among tabs: [Tab], selectedID: Tab.ID, now: Date) throws -> [ArchivedTab] {
        let ids = Set(archiving.map(\.id))
        let entries = try TabArchive.shared.load().filter { !ids.contains($0.id) }
            + archiving.map { ArchivedTab(tab: savedTab($0), archivedAt: now) }
        let (source, destination) = (directory, TabArchive.shared.directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        save(tabs: tabs, selectedID: selectedID)
        try queue.sync { try copyFiles(of: ids, from: source, to: destination) }
        try TabArchive.shared.save(entries)
        return entries
    }

    static func restoreArchived(_ entry: ArchivedTab) throws -> Tab {
        let (source, destination) = (TabArchive.shared.directory, directory)
        try queue.sync { try copyFiles(of: [entry.id], from: source, to: destination) }
        return restoredTab(entry.tab)
    }

    static func removeArchived(_ id: UUID) throws -> [ArchivedTab] {
        let entries = try TabArchive.shared.load().filter { $0.id != id }
        queue.sync {}
        try TabArchive.shared.save(entries)
        let directory = TabArchive.shared.directory
        queue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            for name in names where name.hasPrefix(id.uuidString + ".") {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
        return entries
    }

    nonisolated private static func copyFiles(of ids: Set<UUID>, from source: URL, to destination: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: source.path(percentEncoded: false))
        for name in names {
            let stem = String(name.split(separator: ".", maxSplits: 1).first ?? "")
            guard let id = UUID(uuidString: stem), ids.contains(id) else { continue }
            let target = destination.appending(path: name)
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source.appending(path: name), to: target)
        }
    }

    nonisolated private static func moveFiles(of ids: Set<UUID>, from source: URL, to destination: URL) {
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
    nonisolated private static func image(_ url: URL) -> UIImage? {
        (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
    }

    /// Deletes files belonging to tabs that no longer exist, and held-link
    /// files of tabs whose held link has closed.
    nonisolated private static func removeFiles(in directory: URL, except keep: Set<UUID>, peeks: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names where name != "session.json" {
            let parts = name.split(separator: ".", maxSplits: 1)
            guard let id = UUID(uuidString: String(parts.first ?? "")) else { continue }
            let isPeekFile = parts.count > 1 && parts[1].hasPrefix("peek.")
            if !keep.contains(id) || (isPeekFile && !peeks.contains(id)) {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
    }
}
