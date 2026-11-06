import SwiftUI
import UIKit

/// Fetches each site's icon once and keeps it on disk, so chips and the voice
/// layout can show it. Only the site's own address is contacted, nothing about
/// what you search, and only for sites in your list.
@MainActor @Observable
final class SiteIconStore {
    static let shared = SiteIconStore()

    /// Changes when an icon arrives, so views showing the fallback refresh.
    private(set) var revision = 0
    @ObservationIgnored private var images: [String: UIImage] = [:]
    @ObservationIgnored private var colors: [String: Color] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []

    private nonisolated static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "SiteIcons", directoryHint: .isDirectory)
    }()

    /// Returns the normalized host cache path for the stored PNG icon.
    private nonisolated static func file(_ host: String) -> URL {
        folder.appending(path: host.lowercased().replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// The icon if it's here already; otherwise starts getting it.
    func image(forHost host: String) -> UIImage? {
        _ = revision
        guard !host.isEmpty else { return nil }
        if let image = images[host] { return image }
        load(host)
        return nil
    }

    /// The icon's main colour, once it has arrived.
    func dominantColor(forHost host: String) -> Color? {
        guard let image = image(forHost: host) else { return nil }
        if let color = colors[host] { return color }
        let color = image.dominantColor()
        colors[host] = color
        return color
    }

    /// Fetches again, replacing what's stored. For the "Refresh icon" button.
    func refresh(host: String) {
        guard !host.isEmpty else { return }
        images[host] = nil
        colors[host] = nil
        failed.remove(host)
        try? FileManager.default.removeItem(at: Self.file(host))
        revision += 1
        load(host)
    }

    /// Starts loading distinct uncached hosts without waiting for a view to request them.
    func prefetch(hosts: [String]) {
        for host in Set(hosts) where !host.isEmpty && images[host] == nil { load(host) }
    }

    /// Coalesces pending requests and publishes an icon or remembers a failed attempt.
    private func load(_ host: String) {
        guard !pending.contains(host), !failed.contains(host) else { return }
        pending.insert(host)
        Task {
            let image = await Self.loadFromDiskOrNetwork(host)
            pending.remove(host)
            if let image {
                images[host] = image
                colors[host] = nil
                revision += 1
            } else {
                failed.insert(host)
            }
        }
    }

    /// Reads the cached PNG first, otherwise fetches and atomically caches a site icon.
    private nonisolated static func loadFromDiskOrNetwork(_ host: String) async -> UIImage? {
        let url = file(host)
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) { return image }
        guard let image = await fetch(host), let png = image.pngData() else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: url, options: .atomic)
        return image
    }

    // MARK: Fetching

    /// Tries discovered homepage icons and favicon.ico with ephemeral, bounded requests.
    private nonisolated static func fetch(_ host: String) async -> UIImage? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration)
        guard let home = URL(string: "https://\(host)/") else { return nil }

        var candidates: [URL] = []
        if let (data, response) = try? await session.data(from: home),
           (response as? HTTPURLResponse)?.statusCode == 200,
           data.count < 1_500_000,
           let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            candidates = iconLinks(in: html, base: response.url ?? home)
        }
        candidates.append(home.appending(path: "favicon.ico"))

        for candidate in candidates {
            guard let (data, response) = try? await session.data(from: candidate),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 2_000_000,
                  let image = UIImage(data: data), image.size.width >= 16 else { continue }
            return image.square(side: 64)
        }
        return nil
    }

    /// Touch icons first (sharper), then ordinary ones; SVG can't be drawn here.
    nonisolated static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var touch: [URL] = []
        var plain: [URL] = []
        for match in tags.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "https",
                  !url.path.lowercased().hasSuffix(".svg") else { continue }
            if rel.contains("apple-touch-icon") { touch.append(url) } else { plain.append(url) }
        }
        return touch + plain
    }

    /// Extracts a quoted HTML attribute from a link tag without depending on attribute order.
    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')", options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }
}

private extension UIImage {
    /// Fits an icon into a square canvas while preserving its aspect ratio.
    nonisolated func square(side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scale = min(side / size.width, side / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            draw(in: CGRect(x: (side - drawn.width) / 2, y: (side - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
    }

    /// The most vivid colour in the picture, ignoring transparent, white and grey pixels.
    func dominantColor() -> Color? {
        guard let cg = cgImage else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(pixels[index]) / 255 / alpha, g = Double(pixels[index + 1]) / 255 / alpha, b = Double(pixels[index + 2]) / 255 / alpha
            let high = max(r, g, b), low = min(r, g, b)
            let weight = (high - low) * alpha
            guard weight > 0.15 else { continue }
            red += r * weight; green += g * weight; blue += b * weight; total += weight
        }
        guard total > 0 else { return nil }
        return Color(red: red / total, green: green / total, blue: blue / total)
    }
}

/// Works out what a site's chip or voice tile shows.
enum SiteAppearance {
    /// The site's colour, or the one picked for this place.
    static func color(siteID: String, host: String, setting: SiteColor) -> Color {
        switch setting {
        case .custom(let hex):
            return SiteColors.color(hex: hex) ?? .accentColor
        case .site:
            if let brand = SiteColors.brand[siteID], let color = SiteColors.color(hex: brand) { return color }
            return SiteIconStore.shared.dominantColor(forHost: host) ?? .accentColor
        }
    }

    /// Returns a bundled fallback asset for known sites, or nil for other sites.
    static func bundledLogo(siteID: String) -> String? {
        switch siteID {
        case "youtube": "ProviderYoutube"
        case "wikipedia": "ProviderWikipedia"
        case "reddit": "ProviderReddit"
        case "amazon": "ProviderAmazon"
        case "google-images", "google": "ProviderGoogle"
        case "google-translate": "ProviderGoogletranslate"
        case "imdb": "ProviderImdb"
        default: nil
        }
    }
}

/// A site's icon: its fetched favicon, a bundled logo, a globe, or a symbol.
struct SiteIconView: View {
    let icon: SiteIconChoice
    let siteID: String
    let host: String
    var tint: Color = .primary
    private let store = SiteIconStore.shared

    var body: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).foregroundStyle(tint)
        case .site:
            if let image = store.image(forHost: host) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 3))
            } else if let asset = SiteAppearance.bundledLogo(siteID: siteID) {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(tint)
            } else {
                Image(systemName: "globe").foregroundStyle(tint)
            }
        }
    }
}
