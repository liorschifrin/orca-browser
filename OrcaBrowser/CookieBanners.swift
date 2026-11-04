import Foundation

/// Help for pages whose cookie banner can't be hidden by AdGuard's list alone.
///
/// AdGuard's cookie list deals with the big consent platforms (Sourcepoint,
/// OneTrust, Fides) mostly by clicking "reject" from a script, which WebKit's
/// content rules can't do. So two things fill the gap here:
/// - `hideRulesJSON`: plain hide rules for those platforms, built in.
/// - `unlockScrollScript`: banners that lock the page leave it locked once
///   hidden. This clears the lock.
enum CookieBanners {
    /// Hides the banner containers of common consent platforms. Selectors are
    /// ids and classes the platforms use on every site that embeds them.
    private static let hiddenSelectors = [
        // Sourcepoint: Guardian, Spiegel, BBC and many publishers.
        "div[id^=\"sp_message_container_\"]",
        // OneTrust: CNN and many others.
        "#onetrust-consent-sdk", "#onetrust-banner-sdk", ".onetrust-pc-dark-filter",
        // Fides: New York Times.
        "#fides-banner-container", ".fides-modal-overlay",
        // BBC's own banner.
        "#cookiePrompt", "#bbccookies",
        // Google.
        "div#xe7COe",
        // Others.
        "#didomi-host", ".didomi-popup-backdrop",
        "#CybotCookiebotDialog", "#CybotCookiebotDialogBodyUnderlay",
        ".qc-cmp2-container",
        "#truste-consent-track", "#consent_blackbar",
        "#usercentrics-root", "#uc-banner-modal",
        ".osano-cm-window", "#iubenda-cs-banner", "#BorlabsCookieBox",
        "#cmplz-cookiebanner-container", ".cky-consent-container", ".cky-overlay",
    ]

    /// The rules above in WebKit's content rule format.
    static let hideRulesJSON: String = {
        let rules: [[String: Any]] = [[
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")],
        ]]
        let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }()

    /// Clears the scroll lock a banner leaves behind, whenever it shows up in
    /// the first ten seconds. Pages that fit the screen are left alone unless
    /// they carry a known lock class: some lock the body on purpose and scroll
    /// something inside it, but the consent platforms lock pages that are taller
    /// than the screen too, and report the screen's height while locked.
    static let unlockScrollScript = """
    (() => {
      if (window.__unlockBannerScroll) return;
      window.__unlockBannerScroll = true;
      const root = document.documentElement;
      const lockClasses = ["sp-message-open", "fides-no-scroll", "ot-sdk-lock", "didomi-popup-open", "cmplz-blocked"];
      let queued = false;
      let observedBody = null;
      const unlock = () => {
        queued = false;
        const body = document.body;
        if (body && body !== observedBody) {
          observedBody = body;
          observer.observe(body, { attributes: true, attributeFilter: ["style", "class"] });
        }
        let locked = false;
        for (const element of [root, body]) {
          if (!element) continue;
          for (const name of lockClasses) {
            if (element.classList.contains(name)) { element.classList.remove(name); locked = true; }
          }
        }
        if (!locked && root.scrollHeight <= window.innerHeight + 1) return;
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
