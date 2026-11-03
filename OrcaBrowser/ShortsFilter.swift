import Foundation
import WebKit

/// Deals with YouTube Shorts in the pages the app shows. Two separate
/// settings, each with its own part:
/// - Hiding: shelves and cards on the home, search and channel pages. A
///   stylesheet hides them. It is injected by a user script that runs in every
///   page, and it checks `window.__hideShorts`, so the setting can change
///   without rebuilding the web view.
/// - Opening as videos: links such as youtube.com/shorts/ID open the normal
///   watch page instead. `watchURL(forShorts:)` does this for full page loads.
///   YouTube is a single-page app, so tapping a Short in a list usually
///   doesn't load a page at all; `redirectScript` catches those taps. It
///   checks `window.__opensShortsAsVideos`.
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
    ytd-mini-guide-entry-renderer[aria-label="Shorts"],
    ytm-pivot-bar-item-renderer:has(.pivot-shorts),
    ytm-pivot-bar-item-renderer:has(a[href^="/shorts"]) {
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

    /// Runs before each page's own scripts. On YouTube, sends taps on Shorts
    /// links to the watch page. YouTube changes the address in place when a
    /// result is tapped, so the app never sees a page load. Two catches:
    /// the tap itself, and any change of address to /shorts/ID.
    private static let redirectScript = """
    (() => {
      const isYouTube = (host) => host === "youtube.com" || host.endsWith(".youtube.com");
      if (!isYouTube(location.hostname)) return;
      const watchURL = (address) => {
        try {
          const url = new URL(address, location.href);
          const match = url.pathname.match(/^\\/shorts\\/([^\\/]+)/);
          if (!match || !isYouTube(url.hostname)) return null;
          return location.origin + "/watch?v=" + encodeURIComponent(match[1]);
        } catch (error) {
          return null;
        }
      };
      document.addEventListener("click", (event) => {
        if (!window.__opensShortsAsVideos) return;
        const link = event.target.closest && event.target.closest("a[href]");
        const target = link && watchURL(link.href);
        if (!target) return;
        event.preventDefault();
        event.stopPropagation();
        location.assign(target);
      }, true);
      // Keeps the page the user came from in the history for pushState, and
      // swaps out the entry for replaceState, which replaces it anyway.
      for (const [name, go] of [["pushState", "assign"], ["replaceState", "replace"]]) {
        const original = history[name];
        history[name] = function (state, title, address) {
          const target = window.__opensShortsAsVideos && address != null && watchURL(String(address));
          if (target) {
            location[go](target);
            return;
          }
          return original.apply(this, arguments);
        };
      }
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

    /// JavaScript that changes the hiding setting in a page that is already open.
    static func setScript(enabled: Bool) -> String {
        "window.__hideShorts = \(enabled); window.__applyHideShorts && window.__applyHideShorts();"
    }

    /// The user script that opens Shorts as videos, for a new web view. Only
    /// the top-level page, since taps happen there.
    static func redirectUserScript(enabled: Bool) -> WKUserScript {
        WKUserScript(
            source: setRedirectScript(enabled: enabled) + redirectScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// JavaScript that changes the opening setting in a page that is already open.
    static func setRedirectScript(enabled: Bool) -> String {
        "window.__opensShortsAsVideos = \(enabled);"
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
