import WebKit

/// Removes Reddit's "Get the best of Reddit in the app" pop-up.
///
/// Reddit slides a bottom sheet over the feed and locks scrolling until it's
/// dismissed. The sheet is an element whose id starts with
/// `configured-xpromo` (class `configured-xpromo`), and the lock is the
/// `rpl-scroll-lock` class on the page body. A stylesheet hides the sheet at
/// once; a watcher then deletes it and lifts the lock, since the page adds
/// both after it has loaded. Only runs on reddit.com, and only while
/// `window.__blockRedditPrompt` is true, so the setting can change without
/// rebuilding the web view. Reddit renames things
/// now and then, so these names may need updating.
enum RedditPrompt {
    private static let script = """
    (() => {
      if (!/(^|\\.)reddit\\.com$/.test(location.hostname)) return;

      const sheets = '[id^="configured-xpromo"], .configured-xpromo';
      const style = document.createElement("style");
      style.textContent = `${sheets} { display: none !important; }`;
      (document.head || document.documentElement).appendChild(style);

      const sweep = () => {
        style.disabled = !window.__blockRedditPrompt;
        if (!window.__blockRedditPrompt) return;
        const found = document.querySelectorAll(sheets);
        if (!found.length) return;
        found.forEach((element) => element.remove());
        document.body?.classList.remove("rpl-scroll-lock");
        document.documentElement.classList.remove("rpl-scroll-lock");
      };

      let pending = false;
      new MutationObserver(() => {
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => { pending = false; sweep(); });
      }).observe(document.documentElement, { childList: true, subtree: true });
      window.__applyRedditPrompt = sweep;
      sweep();
    })();
    """

    /// The user script for a new web view. It starts with the current setting.
    static func userScript(enabled: Bool) -> WKUserScript {
        WKUserScript(
            source: setScript(enabled: enabled) + script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// JavaScript that changes the setting in a page that is already open.
    static func setScript(enabled: Bool) -> String {
        "window.__blockRedditPrompt = \(enabled); window.__applyRedditPrompt && window.__applyRedditPrompt();"
    }
}
