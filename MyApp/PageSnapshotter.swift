import WebKit

/// Takes pictures of pages, for tab cards and for covering a tab while it
/// reloads.
enum PageSnapshotter {
    /// A picture of what `view` shows right now. Take it *before* the view
    /// is hidden: a hidden view may render blank.
    static func capture(_ view: WKWebView) async -> UIImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 400
        guard let image = try? await view.takeSnapshot(configuration: configuration) else { return nil }
        // WebKit renders at the screen's scale (3x on most iPhones). 2x is
        // plenty for cards and the brief stand-in, at under half the memory.
        return await Task.detached(priority: .utility) {
            atTwiceScale(image)
        }.value
    }

    nonisolated private static func atTwiceScale(_ image: UIImage) -> UIImage {
        guard image.scale > 2 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
