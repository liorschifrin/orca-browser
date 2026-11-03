import ImageIO
import SwiftUI

/// Small versions of tab pictures, for the switcher's cards.
///
/// A full page picture takes about 5 MB once decoded, and with a hundred tabs
/// that adds up to more memory than a phone will give the app. A card needs
/// only a fraction of it. So cards of tabs that aren't live get a thumbnail
/// instead: decoded off the main thread straight from the picture's file, at
/// card size, and kept only while recently used. The switcher's memory then
/// stays about the same however many tabs are open.
@MainActor
final class CardThumbnails {
    static let shared = CardThumbnails()

    /// Longest side, in pixels. A card is about two-thirds of the screen
    /// wide, so this is about 2x its size.
    nonisolated private static let maxPixelSize = 1000

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Roughly 25 thumbnails.
        cache.totalCostLimit = 60 * 1024 * 1024
        return cache
    }()
    private var loading: [String: Task<UIImage?, Never>] = [:]

    private init() {}

    private static func key(_ tab: Tab) -> String {
        "\(tab.id.uuidString)#\(tab.snapshotRevision)"
    }

    /// The thumbnail, if it's ready now.
    func cached(for tab: Tab) -> UIImage? {
        tab.isIncognito ? nil : cache.object(forKey: Self.key(tab) as NSString)
    }

    /// The thumbnail, decoding it first if needed. nil if the tab has no
    /// picture.
    func thumbnail(for tab: Tab) async -> UIImage? {
        guard !tab.isIncognito, tab.hasSnapshot else { return nil }
        let key = Self.key(tab)
        if let image = cache.object(forKey: key as NSString) { return image }
        if let task = loading[key] { return await task.value }

        let source = tab.snapshot
        let file = TabPersistence.snapshotFile(for: tab)
        let pending = source == nil ? TabPersistence.loadSnapshot(for: tab) : nil
        let task = Task.detached(priority: .userInitiated) {
            if let image = source ?? pending { return Self.shrink(image) }
            return Self.decode(file)
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        }
        return image
    }

    /// Decodes thumbnails ahead of time, all at once, so cards that are
    /// about to appear don't show up empty.
    func prefetch(_ tabs: [Tab]) async {
        await withTaskGroup(of: Void.self) { group in
            for tab in tabs where tab.snapshot == nil && tab.hasSnapshot {
                group.addTask { _ = await self.thumbnail(for: tab) }
            }
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    nonisolated private static func decode(_ file: URL) -> UIImage? {
        // Reads the file up front rather than mapping it, as
        // `TabPersistence` does, since a save may replace it meanwhile.
        guard let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Decode now, here, rather than on the main thread at first draw.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            .map { UIImage(cgImage: $0) }
    }

    nonisolated private static func shrink(_ image: UIImage) -> UIImage? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, CGFloat(maxPixelSize) / max(pixels.width, pixels.height, 1))
        return image.preparingThumbnail(of: CGSize(width: pixels.width * factor, height: pixels.height * factor))
    }

    nonisolated private static func cost(of image: UIImage) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    }
}

/// A tab's picture for a card: the full one when the tab still has it in
/// memory (a live tab, so it costs nothing extra), else a thumbnail.
struct TabPicture<Content: View>: View {
    let tab: Tab
    @ViewBuilder let content: (UIImage?) -> Content
    @State private var thumbnail: UIImage?

    init(tab: Tab, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        self.tab = tab
        self.content = content
        _thumbnail = State(initialValue: CardThumbnails.shared.cached(for: tab))
    }

    /// Fetch again when there's a new picture, or the full one is let go.
    private struct LoadKey: Equatable {
        var revision: Int
        var isInMemory: Bool
    }

    var body: some View {
        content(tab.snapshot ?? thumbnail)
            .task(id: LoadKey(revision: tab.snapshotRevision, isInMemory: tab.snapshot != nil)) {
                guard tab.snapshot == nil else { return }
                thumbnail = await CardThumbnails.shared.thumbnail(for: tab)
            }
    }
}
