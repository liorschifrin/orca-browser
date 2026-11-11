import WebKit

/// Facts about the page showing in a web view: its icon, whether it's in
/// a language the user reads, and whether it's an article.
enum PageMetadata {
    /// Where the page's icon is. The page itself says (a <link> tag); if it
    /// doesn't, the conventional /favicon.ico. nil for non-web pages.
    static func iconURL(in view: WKWebView) async -> URL? {
        guard let pageURL = view.url, pageURL.scheme?.hasPrefix("http") == true else { return nil }
        let script = """
        (function () {
          var selectors = ['link[rel="apple-touch-icon"]', 'link[rel~="icon"]'];
          for (var i = 0; i < selectors.length; i++) {
            var link = document.querySelector(selectors[i]);
            if (link && link.href) { return link.href; }
          }
          return null;
        })()
        """
        let declared = (try? await view.evaluateJavaScript(script)) as? String
        return declared.flatMap { URL(string: $0) }
            ?? URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
    }

    /// Downloads an icon. Only the site's own server is contacted. nil if it
    /// fails, or is a format iOS can't decode (e.g. SVG).
    static func icon(at url: URL, isIncognito: Bool = false) async -> UIImage? {
        let session = isIncognito ? URLSession(configuration: .ephemeral) : URLSession.shared
        defer { if isIncognito { session.invalidateAndCancel() } }
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    /// Whether the page appears to be in a language the user doesn't read
    /// (see `Translation`). nil if it couldn't be read.
    static func isForeignLanguage(_ view: WKWebView) async -> Bool? {
        guard view.url?.scheme?.hasPrefix("http") == true else { return nil }
        let script = """
        (function () {
          return {
            lang: document.documentElement.lang || '',
            text: (document.body ? document.body.innerText : '').slice(0, 2000)
          };
        })()
        """
        guard let result = (try? await view.evaluateJavaScript(script)) as? [String: Any] else { return nil }
        let declared = result["lang"] as? String ?? ""
        let text = result["text"] as? String ?? ""
        // Language recognition is CPU work; keep it off the main thread.
        return await Task.detached(priority: .utility) {
            Translation.isForeign(declared: declared, text: text)
        }.value
    }

    /// Whether the page is an article (see `ArchivePage`). nil if it couldn't be read.
    static func isArticle(_ view: WKWebView) async -> Bool? {
        guard let pageURL = view.url, ArchivePage.isArchivable(pageURL) else { return nil }
        let script = """
        (function () {
          var og = document.querySelector('meta[property="og:type"]');
          var types = [];
          function collect(node) {
            if (!node || typeof node !== 'object') { return; }
            if (Array.isArray(node)) { node.forEach(collect); return; }
            var type = node['@type'];
            if (typeof type === 'string') { types.push(type); }
            else if (Array.isArray(type)) { type.forEach(function (t) { if (typeof t === 'string') { types.push(t); } }); }
            collect(node['@graph']);
          }
          document.querySelectorAll('script[type="application/ld+json"]').forEach(function (script) {
            try { collect(JSON.parse(script.textContent)); } catch (e) {}
          });
          var articles = document.querySelectorAll('article');
          var words = articles.length === 1
            ? (articles[0].innerText || '').split(/\\s+/).filter(Boolean).length : 0;
          return {
            ogType: og ? (og.content || '') : '',
            types: types,
            published: !!document.querySelector('meta[property="article:published_time"]'),
            words: words
          };
        })()
        """
        guard let result = (try? await view.evaluateJavaScript(script)) as? [String: Any] else { return nil }
        let signals = ArchivePage.ArticleSignals(
            ogType: result["ogType"] as? String ?? "",
            schemaTypes: result["types"] as? [String] ?? [],
            hasPublishedTime: result["published"] as? Bool ?? false,
            articleWords: (result["words"] as? NSNumber)?.intValue ?? 0
        )
        return ArchivePage.isArticle(pageURL, signals: signals)
    }
}
