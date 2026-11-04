import Foundation

/// Helps pages whose cookie banner has been hidden by the content rules.
///
/// Many banners stop the page from scrolling while they are up, and hiding
/// the banner doesn't undo that. This script runs in a page only when banner
/// hiding is on for its site (`ContentBlocker.hidesBanners(on:)`), is injected
/// once the page commits, and stops itself after a few seconds.
enum CookieBanners {
    /// Clears `overflow: hidden` from `html` and `body` whenever it shows up
    /// in the first ten seconds. It leaves pages alone that fit the screen:
    /// those lock the body on purpose and scroll something inside it.
    static let unlockScrollScript = """
    (() => {
      if (window.__unlockBannerScroll) return;
      window.__unlockBannerScroll = true;
      const root = document.documentElement;
      let queued = false;
      let observedBody = null;
      const unlock = () => {
        queued = false;
        const body = document.body;
        if (body && body !== observedBody) {
          observedBody = body;
          observer.observe(body, { attributes: true, attributeFilter: ["style", "class"] });
        }
        if (root.scrollHeight <= window.innerHeight + 1) return;
        for (const element of [root, body]) {
          if (!element) continue;
          const style = getComputedStyle(element);
          if (style.overflowY === "hidden" || style.overflow === "hidden") {
            element.style.setProperty("overflow", "auto", "important");
          }
        }
      };
      const schedule = () => {
        if (!queued) { queued = true; requestAnimationFrame(unlock); }
      };
      const observer = new MutationObserver(schedule);
      // Also watches for <body> arriving, which can be later than this script.
      observer.observe(root, { attributes: true, attributeFilter: ["style", "class"], childList: true });
      schedule();
      setTimeout(() => observer.disconnect(), 10000);
    })();
    """
}
