import WebKit

/// Facts about the page showing in a web view: its icon, and whether it's in
/// a language the user reads.
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
}
