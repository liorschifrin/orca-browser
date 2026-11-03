import SwiftData
import UIKit

/// One page you've visited. There is a single row per address: visiting it
/// again moves it to the top and counts the visit.
@Model
final class HistoryEntry {
    #Unique<HistoryEntry>([\.urlString])
    #Index<HistoryEntry>([\.lastVisited])

    var urlString: String
    var title: String
    /// "apple.com", for searching and display.
    var host: String
    var lastVisited: Date
    var visitCount: Int

    var url: URL? { URL(string: urlString) }

    init(urlString: String, title: String, host: String, lastVisited: Date = .now) {
        self.urlString = urlString
        self.title = title
        self.host = host
        self.lastVisited = lastVisited
        visitCount = 1
    }
}

/// A site's icon, shown beside its pages in the history. One per host, so
/// pages of the same site share it.
@Model
final class HistoryIcon {
    #Unique<HistoryIcon>([\.host])

    var host: String
    var data: Data

    init(host: String, data: Data) {
        self.host = host
        self.data = data
    }
}

/// Where visited pages are remembered, between launches.
///
/// Tabs report to this as their address and title change (see `Tab.sync`).
/// The history screen reads the same container with `@Query`.
@MainActor
@Observable
final class HistoryStore {
    private static var instance: HistoryStore?
    static var shared: HistoryStore {
        if let instance { return instance }
        let store = HistoryStore()
        instance = store
        return store
    }

    private struct PendingVisit {
        let url: URL
        let title: String?
        let isNew: Bool
    }
    private static var pendingVisits: [PendingVisit] = []
    private static var pendingTask: Task<Void, Never>?
    private static var pendingGeneration = 0

    /// Database initialization and visit writes yield to the first page/UI.
    static func deferVisit(_ url: URL, title: String?, isNew: Bool) {
        pendingVisits.append(PendingVisit(url: url, title: title, isNew: isNew))
        guard pendingTask == nil else { return }
        pendingGeneration += 1
        let generation = pendingGeneration
        pendingTask = Task {
            defer { if generation == pendingGeneration { pendingTask = nil } }
            do {
                try await InteractionBudget.shared.waitForIdle()
                drainVisits()
            } catch { }
        }
    }

    private static func drainVisits() {
        let visits = pendingVisits
        pendingVisits.removeAll()
        for visit in visits {
            if visit.isNew { shared.recordVisit(visit.url, title: visit.title) }
            else if let title = visit.title { shared.updateTitle(title, for: visit.url) }
        }
    }

    static func flushIfNeeded() {
        pendingTask?.cancel()
        pendingGeneration += 1
        pendingTask = nil
        if !pendingVisits.isEmpty { drainVisits() }
        instance?.flush()
    }

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// How long a deletion can be undone before it's carried out.
    static let undoWindow: Duration = .seconds(10)
    /// Entries removed from the list but still on disk, until the undo window ends.
    private(set) var hiddenIDs = Set<PersistentIdentifier>()
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    /// While the history screen is open, new visits wait here so the list
    /// doesn't shift under the reader's finger.
    @ObservationIgnored private var isHolding = false
    @ObservationIgnored private var held: [() -> Void] = []

    private init() {
        do {
            container = try ModelContainer(for: HistoryEntry.self, HistoryIcon.self)
        } catch {
            // History is a convenience: if the database can't open, keep it
            // in memory for this run rather than stopping the app.
            container = try! ModelContainer(
                for: HistoryEntry.self, HistoryIcon.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
    }

    /// Only ordinary web pages are worth remembering. Fragments are dropped
    /// so "page#section" and "page" are the same entry.
    private static func key(for url: URL) -> (string: String, host: String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.fragment = nil
        guard let string = components.url?.absoluteString else { return nil }
        return (string, host.replacing("www.", with: "", maxReplacements: 1))
    }

    func holdNewVisits() { isHolding = true }

    func releaseNewVisits() {
        isHolding = false
        commitHidden()
        let pending = held
        held = []
        pending.forEach { $0() }
    }

    private func whenReady(_ change: @escaping () -> Void) {
        if isHolding { held.append(change) } else { change() }
    }

    /// Remembers the site's icon, shrunk to a size a list row needs.
    func saveIcon(_ image: UIImage, for url: URL) {
        whenReady { [self] in storeIcon(image, for: url) }
    }

    private func storeIcon(_ image: UIImage, for url: URL) {
        guard let (_, host) = Self.key(for: url) else { return }
        let side: CGFloat = 64
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let data = small.pngData() else { return }
        var descriptor = FetchDescriptor<HistoryIcon>(predicate: #Predicate { $0.host == host })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.data = data
        } else {
            context.insert(HistoryIcon(host: host, data: data))
        }
        scheduleSave()
    }

    private func entry(for string: String) -> HistoryEntry? {
        var descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.urlString == string })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// A tab arrived at `url`.
    func recordVisit(_ url: URL, title: String?) {
        whenReady { [self] in storeVisit(url, title: title) }
    }

    private func storeVisit(_ url: URL, title: String?) {
        guard let (string, host) = Self.key(for: url) else { return }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let existing = entry(for: string) {
            existing.visitCount += 1
            existing.lastVisited = .now
            if !cleanTitle.isEmpty { existing.title = cleanTitle }
        } else {
            context.insert(HistoryEntry(urlString: string, title: cleanTitle, host: host))
        }
        scheduleSave()
    }

    /// The page at `url` finished naming itself. Doesn't count as a visit.
    func updateTitle(_ title: String, for url: URL) {
        whenReady { [self] in storeTitle(title, for: url) }
    }

    private func storeTitle(_ title: String, for url: URL) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              let (string, _) = Self.key(for: url),
              let existing = entry(for: string), existing.title != cleanTitle
        else { return }
        existing.title = cleanTitle
        scheduleSave()
    }

    /// Takes entries out of the list now; they're deleted for good once the
    /// undo window passes, History closes, or the app is put away.
    func hide(ids: Set<PersistentIdentifier>) {
        guard !ids.isEmpty else { return }
        hiddenIDs.formUnion(ids)
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            commitHidden()
        }
    }

    func hide(_ entry: HistoryEntry) {
        hide(ids: [entry.persistentModelID])
    }

    /// Like `clear(since:)`, but undoable.
    func hide(since date: Date?) {
        let descriptor = date.map { date in
            FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.lastVisited >= date })
        } ?? FetchDescriptor<HistoryEntry>()
        let entries = (try? context.fetch(descriptor)) ?? []
        hide(ids: Set(entries.map(\.persistentModelID)))
    }

    /// Brings back everything hidden, as if it was never deleted.
    func undo() {
        commitTask?.cancel()
        hiddenIDs = []
    }

    /// Deletes the hidden entries for real.
    func commitHidden() {
        commitTask?.cancel()
        guard !hiddenIDs.isEmpty else { return }
        for id in hiddenIDs {
            if let entry = context.model(for: id) as? HistoryEntry { context.delete(entry) }
        }
        hiddenIDs = []
        try? context.save()
        removeUnusedIcons()
        scheduleSave()
    }

    /// Deletes everything visited at or after `date`; nil clears all of it.
    func clear(since date: Date?) {
        if let date {
            try? context.delete(model: HistoryEntry.self, where: #Predicate { $0.lastVisited >= date })
        } else {
            try? context.delete(model: HistoryEntry.self)
        }
        removeUnusedIcons()
        save()
    }

    private func removeUnusedIcons() {
        let hosts = Set(((try? context.fetch(FetchDescriptor<HistoryEntry>())) ?? []).map(\.host))
        for icon in (try? context.fetch(FetchDescriptor<HistoryIcon>())) ?? [] where !hosts.contains(icon.host) {
            context.delete(icon)
        }
    }

    /// Saves soon, but not on every little change.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        saveTask?.cancel()
        try? context.save()
    }

    /// The app is going away: finish any pending deletion and write everything.
    func flush() {
        commitHidden()
        save()
    }
}
