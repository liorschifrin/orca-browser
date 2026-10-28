import Foundation
import WebKit

/// Hides YouTube Shorts in the pages the app shows.
///
/// Two parts, because Shorts show up in two ways:
/// - Shelves and cards on the home, search and channel pages. A stylesheet
///   hides them. It is injected by a user script that runs in every page, and
///   it checks `window.__hideShorts`, so the setting can change without
///   rebuilding the web view.
/// - Direct links such as youtube.com/shorts/ID. `watchURL(forShorts:)` turns
///   them into the normal watch page instead.
enum ShortsFilter {
    /// Hides Shorts shelves and cards. The selectors cover desktop and mobile
    /// YouTube. YouTube changes its markup often, so these may need updating.
    private static let css = """
    ytd-reel-shelf-renderer,
    ytm-reel-shelf-renderer,
    ytd-rich-shelf-renderer[is-shorts],
    grid-shelf-view-model:has(a[href^="/shorts/"]),
    ytd-rich-item-renderer:has(a[href^="/shorts/"]),
    ytd-video-renderer:has(a[href^="/shorts/"]),
    ytd-compact-video-renderer:has(a[href^="/shorts/"]),
    ytm-shorts-lockup-view-model,
    ytm-shorts-lockup-view-model-v2,
    ytd-guide-entry-renderer:has(a[href="/shorts"]),
    ytd-mini-guide-entry-renderer[aria-label="Shorts"] {
        display: none !important;
    }
    """

    /// Runs before each page's own scripts. Adds or removes the stylesheet
    /// based on `window.__hideShorts`.
    private static let pageScript = """
    (() => {
      const styleID = "hide-shorts-style";
      window.__applyHideShorts = () => {
        const existing = document.getElementById(styleID);
        if (window.__hideShorts) {
          if (!existing) {
            const style = document.createElement("style");
            style.id = styleID;
            style.textContent = `\(css)`;
            (document.head || document.documentElement).appendChild(style);
          }
        } else if (existing) {
          existing.remove();
        }
      };
      window.__applyHideShorts();
    })();
    """

    /// The user script for a new web view. It starts with the current setting.
    static func userScript(enabled: Bool) -> WKUserScript {
        WKUserScript(
            source: setScript(enabled: enabled) + pageScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    /// JavaScript that changes the setting in a page that is already open.
    static func setScript(enabled: Bool) -> String {
        "window.__hideShorts = \(enabled); window.__applyHideShorts && window.__applyHideShorts();"
    }

    /// For a youtube.com/shorts/ID address, the matching watch address
    /// (youtube.com/watch?v=ID). Returns nil for any other address.
    static func watchURL(forShorts url: URL) -> URL? {
        guard let host = url.host()?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com")
        else { return nil }

        let parts = url.pathComponents // ["/", "shorts", "ID"]
        guard parts.count >= 3, parts[1] == "shorts", !parts[2].isEmpty else { return nil }

        var components = URLComponents(string: "https://www.youtube.com/watch")
        components?.queryItems = [URLQueryItem(name: "v", value: parts[2])]
        return components?.url
    }
}
