import OSLog
import ImageIO
import SwiftUI

/// Small versions of tab pictures, for the switcher's cards.
///
/// A full page picture takes about 5 MB once decoded, and with a hundred tabs
/// that adds up to more memory than a phone will give the app. A card needs
/// only a fraction of it. All cards use a prepared thumbnail
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
    private var isDecoding = false

    private init() {}

    private static func key(_ tab: Tab) -> String {
        "\(tab.id.uuidString)#\(tab.snapshotRevision)"
    }

    /// The thumbnail, if it's ready now.
    func cached(for tab: Tab) -> UIImage? {
        cache.object(forKey: Self.key(tab) as NSString)
    }

    /// The thumbnail, decoding it first if needed. nil if the tab has no
    /// picture.
    func thumbnail(for tab: Tab) async -> UIImage? {
        guard tab.hasSnapshot else { return nil }
        let key = Self.key(tab)
        // One decode at a time. Canceled/offscreen requests leave before they
        // take a slot; a long swipe cannot flood the device with image work.
        do {
            while true {
                try await InteractionBudget.shared.waitForIdle(allowSwitcher: true)
                if let image = cache.object(forKey: key as NSString) { return image }
                if !isDecoding { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
        } catch { return nil }
        isDecoding = true
        defer { isDecoding = false }
        let source = tab.snapshot ?? TabPersistence.pendingSnapshot(for: tab)
        let file = TabPersistence.snapshotFile(for: tab)
        let interval = PerformanceTrace.signposter.beginInterval("Card thumbnail")
        defer { PerformanceTrace.signposter.endInterval("Card thumbnail", interval) }
        let image = await Task.detached(priority: .utility) {
            if let source { return Self.shrink(source) }
            return Self.decode(file)
        }.value
        guard !Task.isCancelled, key == Self.key(tab) else { return nil }
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        }
        return image
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

/// Cards draw only prepared thumbnails, never lazily decoded full-size images.
struct TabPicture<Content: View>: View {
    let tab: Tab
    @ViewBuilder let content: (UIImage?) -> Content
    @State private var thumbnail: UIImage?
    @Environment(\.thumbnailDelay) private var delay

    init(tab: Tab, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        self.tab = tab
        self.content = content
        _thumbnail = State(initialValue: CardThumbnails.shared.cached(for: tab))
    }

    /// Fetch again when there's a new picture, or the full one is let go.
    private struct LoadKey: Equatable {
        var revision: Int
        var isInMemory: Bool
        var delay: Int
    }

    var body: some View {
        content(thumbnail)
            .task(id: LoadKey(revision: tab.snapshotRevision, isInMemory: tab.snapshot != nil, delay: delay)) {
                do {
                    // First draw uses only the cache or a placeholder. Focused
                    // cards load first after the entrance/drag has settled.
                    try await Task.sleep(for: .milliseconds(delay))
                    let loaded = await CardThumbnails.shared.thumbnail(for: tab)
                    guard !Task.isCancelled else { return }
                    if let loaded { thumbnail = loaded }
                } catch { }
            }
    }
}

private struct ThumbnailDelayKey: EnvironmentKey {
    static let defaultValue = 400
}

extension EnvironmentValues {
    var thumbnailDelay: Int {
        get { self[ThumbnailDelayKey.self] }
        set { self[ThumbnailDelayKey.self] = newValue }
    }
}
