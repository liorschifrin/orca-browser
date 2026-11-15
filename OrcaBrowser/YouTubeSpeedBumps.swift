import WebKit

/// Makes YouTube slower to drift through. Three parts are locked, and each
/// opens only after a button starts a countdown (`seconds`) that runs out:
/// - The home page's recommendations. Unlocking lasts until you leave home.
/// - The video on a watch page. The description and comments stay open.
/// - The other videos under it. Both unlocks last for that one video, so the
///   next video (autoplay included) is locked again.
/// Search, subscriptions and channels aren't touched, so a video you went
/// looking for is only one countdown away.
///
/// The countdown only runs while the page is on screen. Only the top-level
/// mobile YouTube page, and only while `window.__orcaSpeedBumps` is true, so
/// the setting can change without rebuilding the web view. YouTube changes
/// its markup often, so the element names may need updating.
enum YouTubeSpeedBumps {
    static let seconds = 10

    private static let script = """
    (() => {
      if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;
      const SECONDS = \(seconds);

      const style = document.createElement("style");
      style.textContent = `
        html.orca-lock-home ytm-browse,
        html.orca-lock-related .related-items-container { display: none !important; }
        .orca-bump {
          display: flex; flex-direction: column; align-items: center; justify-content: center;
          gap: 12px; padding: 24px 16px; box-sizing: border-box; text-align: center;
          font: 400 14px -apple-system, Roboto, sans-serif;
          color: #606060;
        }
        .orca-bump button {
          font: 500 15px -apple-system, Roboto, sans-serif; padding: 10px 20px;
          border: 0; border-radius: 18px; min-width: 180px;
          color: #0f0f0f; background: rgba(0, 0, 0, 0.05);
          font-variant-numeric: tabular-nums; -webkit-tap-highlight-color: transparent;
        }
        /* YouTube marks its dark theme with an attribute on the page. */
        html:is([dark], [darker-dark-theme]) .orca-bump { color: #aaa; }
        html:is([dark], [darker-dark-theme]) .orca-bump button {
          color: #f1f1f1; background: rgba(255, 255, 255, 0.1);
        }
        #orca-bump-home { position: fixed; left: 0; right: 0; top: 35%; z-index: 1; }
        #orca-bump-player {
          position: absolute; inset: 0; z-index: 1000; background: #000; color: #aaa;
        }
        #orca-bump-player button { color: #fff; background: rgba(255, 255, 255, 0.15); }
      `;
      (document.head || document.documentElement).appendChild(style);

      // What's been opened: "home" until you leave it, and per video ID
      // "watch:ID" and "related:ID". Countdowns in progress, by the same keys,
      // as the seconds left.
      const unlocked = new Set();
      const counting = new Map();

      const videoID = () => location.pathname === "/watch" ? new URLSearchParams(location.search).get("v") : null;
      const isLocked = (key) => window.__orcaSpeedBumps && key != null && !unlocked.has(key);

      const card = (id, message, action, key) => {
        let element = document.getElementById(id);
        if (!element) {
          element = document.createElement("div");
          element.id = id;
          element.className = "orca-bump";
          // Not innerHTML: YouTube's page only allows it for its own markup.
          element.append(document.createElement("div"), document.createElement("button"));
          element.addEventListener("click", (event) => event.stopPropagation());
          element.querySelector("button").addEventListener("click", (event) => {
            event.preventDefault();
            const key = element.dataset.key;
            if (counting.has(key)) counting.delete(key);
            else counting.set(key, SECONDS);
            sweep();
          });
        }
        element.dataset.key = key;
        element.firstChild.textContent = counting.has(key)
          ? "Still want to? Tap to stop."
          : message;
        element.lastChild.textContent = counting.has(key)
          ? `Unlocking in ${counting.get(key)}…`
          : action;
        return element;
      };
      const remove = (id) => document.getElementById(id)?.remove();

      // Pauses the video while it's locked. Media events don't bubble, so
      // this listens on the way down.
      const holdVideo = (event) => {
        const video = event.target;
        if (video instanceof HTMLMediaElement && isLocked(videoID() && "watch:" + videoID())) {
          video.pause();
        }
      };
      document.addEventListener("play", holdVideo, true);
      document.addEventListener("playing", holdVideo, true);

      let lastPath = null;
      const sweep = () => {
        const id = videoID();
        const homeKey = location.pathname === "/" ? "home" : null;
        const watchKey = id && "watch:" + id;
        const relatedKey = id && "related:" + id;
        const root = document.documentElement;

        const path = location.pathname + "?" + (id || "");
        if (path !== lastPath) {
          // A new page: home locks again, and countdowns for other pages
          // stop. Video unlocks are kept, so going back to a video you
          // opened doesn't ask again.
          lastPath = path;
          if (!homeKey) unlocked.delete("home");
          for (const key of counting.keys()) {
            if (key !== homeKey && key !== watchKey && key !== relatedKey) counting.delete(key);
          }
        }

        root.classList.toggle("orca-lock-home", isLocked(homeKey));
        if (isLocked(homeKey)) {
          const element = card("orca-bump-home", "Recommendations are hidden.", "Show recommendations", homeKey);
          if (!element.isConnected) document.body?.appendChild(element);
        } else {
          remove("orca-bump-home");
        }

        const player = document.getElementById("player-container-id");
        if (isLocked(watchKey) && player) {
          const element = card("orca-bump-player", "Here for this video?", "Watch video", watchKey);
          if (element.parentElement !== player) player.appendChild(element);
          document.querySelectorAll("video").forEach((video) => video.paused || video.pause());
        } else {
          remove("orca-bump-player");
        }

        const related = document.querySelector(".related-items-container");
        root.classList.toggle("orca-lock-related", isLocked(relatedKey));
        if (isLocked(relatedKey) && related) {
          const element = card("orca-bump-related", "More videos are hidden.", "Show more videos", relatedKey);
          if (element.nextElementSibling !== related) related.before(element);
        } else {
          remove("orca-bump-related");
        }
      };

      // The countdowns. They wait while the page is off screen.
      setInterval(() => {
        if (!counting.size || document.visibilityState !== "visible") return;
        for (const [key, left] of counting) {
          if (left > 1) {
            counting.set(key, left - 1);
            continue;
          }
          counting.delete(key);
          unlocked.add(key);
          if (key.startsWith("watch:")) {
            document.querySelector("#player-container-id video")?.play()?.catch(() => {});
          }
        }
        sweep();
      }, 1000);

      let pending = false;
      new MutationObserver(() => {
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => { pending = false; sweep(); });
      }).observe(document.documentElement, { childList: true, subtree: true });
      window.__applyOrcaSpeedBumps = sweep;
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
        "window.__orcaSpeedBumps = \(enabled); window.__applyOrcaSpeedBumps && window.__applyOrcaSpeedBumps();"
    }
}
