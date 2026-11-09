import Foundation

/// Opens a page in archive.ph (archive.today), which keeps a saved copy of
/// articles, often without the paywall. Also works out whether a page is an
/// article, so the browser can offer the button on its own.
enum ArchivePage {
    /// archive.today answers on several names; a page already there needs no button.
    nonisolated static let archiveHosts: Set<String> = [
        "archive.ph", "archive.today", "archive.is", "archive.li", "archive.vn", "archive.fo", "archive.md",
    ]

    /// The newest saved copy of `page`, or archive.ph's offer to save one if
    /// there isn't one yet. nil for pages that can't be archived.
    nonisolated static func url(for page: URL) -> URL? {
        guard isArchivable(page),
              var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        // Tracking parameters would miss a copy someone else already saved.
        components.fragment = nil
        components.queryItems = components.queryItems?.filter { !isTrackingParameter($0.name) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        guard let address = components.string else { return nil }
        return URL(string: "https://archive.ph/newest/" + address)
    }

    nonisolated static func isArchivable(_ page: URL) -> Bool {
        guard let scheme = page.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = page.host()?.lowercased() else { return false }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return !archiveHosts.contains(bare)
    }

    private nonisolated static func isTrackingParameter(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("utm_") || ["fbclid", "gclid", "mc_cid", "mc_eid", "cmpid"].contains(name)
    }

    /// What a page says about itself, read by `PageMetadata.isArticle`.
    nonisolated struct ArticleSignals {
        var ogType = ""
        /// Every schema.org `@type` in the page's JSON-LD.
        var schemaTypes: [String] = []
        var hasPublishedTime = false
        /// Words in the page's only `<article>`, 0 if there is none or several.
        var articleWords = 0
    }

    private nonisolated static let articleTypes: Set<String> = [
        "article", "newsarticle", "blogposting", "reportagenewsarticle", "analysisnewsarticle",
        "opinionnewsarticle", "backgroundnewsarticle", "reviewnewsarticle", "scholarlyarticle",
        "techarticle", "report", "liveblogposting",
    ]

    /// Sites mark articles for link previews and search engines, so those
    /// marks come first. Pages without any still count when they hold one
    /// long `<article>`. A site's front page is never an article.
    nonisolated static func isArticle(_ page: URL, signals: ArticleSignals) -> Bool {
        guard isArchivable(page), page.path() != "/", !page.path().isEmpty else { return false }
        if signals.ogType.lowercased() == "article" { return true }
        if signals.schemaTypes.contains(where: { articleTypes.contains($0.lowercased()) }) { return true }
        if signals.hasPublishedTime { return true }
        return signals.articleWords >= 300
    }
}
