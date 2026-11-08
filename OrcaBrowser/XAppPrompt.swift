import WebKit

/// Dismiss X's app promotion through its own close button, so its focus and
/// scroll locks are cleaned up too. Hide the separate reply-list app promotion
/// without hiding articles or authentication dialogs.
enum XAppPrompt {
    static let source = """
    (() => {
      if (!["x.com", "www.x.com", "twitter.com", "www.twitter.com"].includes(location.hostname)) return;
      const dismiss = () => {
        document.querySelector(
          '[role="dialog"][data-interaction="app-store-obstruction"] button[aria-label="Dismiss"]'
        )?.click();
        for (const panel of document.querySelectorAll('aside, [role="complementary"]')) {
          const heading = panel.querySelector('h1, h2, h3, [role="heading"]');
          if (heading?.textContent.trim() !== "See all the replies") continue;
          if (panel.querySelector('article, [role="article"]')) continue;
          if (!panel.querySelector('a[href*="launch_app_store"]')) continue;
          panel.style.setProperty("display", "none", "important");
        }
      };
      let pending = false;
      new MutationObserver(() => {
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => { pending = false; dismiss(); });
      }).observe(document.documentElement, { childList: true, subtree: true,
        attributes: true, attributeFilter: ["data-state"] });
      dismiss();
    })();
    """

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }
}
