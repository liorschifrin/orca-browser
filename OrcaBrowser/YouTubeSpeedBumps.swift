import WebKit

/// Makes YouTube slower to drift through. Three parts are locked, and each
/// opens only after a button starts a countdown that runs out:
/// - The home page's recommendations. Unlocking lasts until you leave home.
/// - The video on a watch page. The description and comments stay open. It
///   can also be opened for listening only, after its own countdown: the
///   video plays with the picture still covered, for music and podcasts.
/// - The other videos under it. Unlocks on a watch page last for that one
///   video, so the next video (autoplay included) is locked again.
/// Search, subscriptions and channels aren't touched, so a video you went
/// looking for is only one countdown away.
///
/// How long each countdown is comes from `Settings`, with longer ones at
/// night if you set them. A countdown only runs while the page is on screen:
/// the app says when its tab isn't showing or the app isn't open
/// (`onScreenScript`), since YouTube's audio keeps the page running.
/// Only the top-level mobile YouTube page, and only while
/// `window.__orcaSpeedBumps` holds settings, so they can change without
/// rebuilding the web view. YouTube changes its markup often, so the element
/// names may need updating.
///
/// The script runs in its own script world. `BackgroundPlayback` tells the
/// page world that the page is always visible, and the countdown needs the
/// truth.
enum YouTubeSpeedBumps {
    static let world = WKContentWorld.world(name: "OrcaSpeedBumps")

    /// How long, in seconds, each countdown is.
    struct Times: Codable, Equatable {
        var home = 10
        var video = 10
        var moreVideos = 10
        var audio = 5
    }

    /// The countdown lengths, and the hours that use the night ones.
    struct Settings: Codable, Equatable {
        var day = Times()
        var hasNightTimes = false
        /// Minutes after midnight. The night hours may cross midnight.
        var nightStart = 22 * 60
        var nightEnd = 6 * 60
        var night = Times(home: 30, video: 30, moreVideos: 30, audio: 10)
    }

    private static let script = """
    (() => {
      // Mobile YouTube only: the desktop site's player and lists are built
      // differently, and a video locked there would have no way to open.
      if (location.hostname !== "m.youtube.com") return;

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
          border: 0; border-radius: 18px; min-width: 200px;
          color: #0f0f0f; background: rgba(0, 0, 0, 0.05);
          font-variant-numeric: tabular-nums; -webkit-tap-highlight-color: transparent;
        }
        .orca-bump button[hidden] { display: none; }
        /* YouTube marks its dark theme with an attribute on the page. */
        html:is([dark], [darker-dark-theme]) .orca-bump { color: #aaa; }
        html:is([dark], [darker-dark-theme]) .orca-bump button {
          color: #f1f1f1; background: rgba(255, 255, 255, 0.1);
        }
        #orca-bump-home { position: fixed; left: 0; right: 0; top: 35%; z-index: 1; }
        #orca-bump-player {
          position: absolute; inset: 0; z-index: 1000; background: #000; color: #aaa; gap: 10px;
        }
        #orca-bump-player button { color: #fff; background: rgba(255, 255, 255, 0.15); }
      `;
      (document.head || document.documentElement).appendChild(style);

      // What's been opened: "home" until you leave it, and per video ID
      // "watch:ID", "listen:ID" and "related:ID". Countdowns in progress, by
      // the same keys, as the seconds left.
      const unlocked = new Set();
      const counting = new Map();

      const settings = () => window.__orcaSpeedBumps;
      const isOnScreen = () => window.__orcaOnScreen !== false && document.visibilityState === "visible";
      // The countdown lengths for now: the night ones during the night hours.
      const times = () => {
        const { day, hasNightTimes, nightStart, nightEnd, night } = settings();
        if (!hasNightTimes || nightStart === nightEnd) return day;
        const date = new Date();
        const minute = date.getHours() * 60 + date.getMinutes();
        const isNight = nightStart < nightEnd
          ? minute >= nightStart && minute < nightEnd
          : minute >= nightStart || minute < nightEnd;
        return isNight ? night : day;
      };
      const secondsFor = (key) => {
        const now = times();
        const kind = key.split(":")[0];
        return { home: now.home, watch: now.video, listen: now.audio, related: now.moreVideos }[kind];
      };

      const videoID = () => location.pathname === "/watch" ? new URLSearchParams(location.search).get("v") : null;
      const isLocked = (key) => !!settings() && key != null && !unlocked.has(key);
      // The video may play: it was opened for watching or for listening.
      const mayPlay = (id) => !id || !isLocked("watch:" + id) || !isLocked("listen:" + id);

      // Text is only written when it changes: the page is watched for
      // changes, and writing the same text again would count as one.
      const setText = (node, text) => { if (node.textContent !== text) node.textContent = text; };

      // A card with a message and buttons. Most start a countdown (`key`);
      // while one counts down, the others hide and its button stops it. A
      // button with `run` does that instead.
      const card = (id, message, actions) => {
        let element = document.getElementById(id);
        if (!element) {
          element = document.createElement("div");
          element.id = id;
          element.className = "orca-bump";
          // Not innerHTML: YouTube's page only allows it for its own markup.
          element.append(document.createElement("div"));
          element.addEventListener("click", (event) => event.stopPropagation());
        }
        while (element.children.length - 1 < actions.length) {
          const button = document.createElement("button");
          button.type = "button";
          button.addEventListener("click", (event) => {
            event.preventDefault();
            if (button.orcaRun) {
              button.orcaRun();
              sweep();
              return;
            }
            const key = button.dataset.key;
            if (counting.has(key)) {
              counting.delete(key);
            } else {
              for (const other of element.querySelectorAll("button")) counting.delete(other.dataset.key);
              const seconds = secondsFor(key);
              if (seconds > 0) counting.set(key, seconds);
              else unlock(key);
            }
            sweep();
          });
          element.append(button);
        }
        while (element.children.length - 1 > actions.length) element.lastChild.remove();

        const active = actions.find((action) => counting.has(action.key));
        setText(element.firstChild, active ? "Still want to? Tap to stop." : message);
        actions.forEach((action, index) => {
          const button = element.children[index + 1];
          button.orcaRun = action.run;
          if (action.key) button.dataset.key = action.key;
          button.hidden = active != null && active !== action;
          setText(button, action.run ? action.label : counting.has(action.key)
            ? `Unlocking in ${counting.get(action.key)}…`
            : `${action.label} (${secondsFor(action.key)}s)`);
        });
        return element;
      };
      const remove = (id) => document.getElementById(id)?.remove();

      const unlock = (key) => {
        unlocked.add(key);
        if (key.startsWith("watch:") || key.startsWith("listen:")) {
          document.querySelector("#player-container-id video")?.play()?.catch(() => {});
        }
      };

      // Pauses the video while it's locked. Media events don't bubble, so
      // this listens on the way down.
      const holdVideo = (event) => {
        if (event.target instanceof HTMLMediaElement && !mayPlay(videoID())) event.target.pause();
      };
      document.addEventListener("play", holdVideo, true);
      document.addEventListener("playing", holdVideo, true);

      // Listening keeps the picture out of fullscreen and picture in picture
      // too. Background audio doesn't need either. Checked when the mode
      // changes, and on every sweep in case the page stopped that event.
      const keepInline = (video) => {
        const id = videoID();
        if (!id || !isLocked("watch:" + id) || isLocked("listen:" + id)) return;
        if (video.webkitPresentationMode && video.webkitPresentationMode !== "inline") {
          video.webkitSetPresentationMode("inline");
        }
      };
      window.addEventListener("webkitpresentationmodechanged", (event) => {
        if (event.target instanceof HTMLVideoElement) keepInline(event.target);
      }, true);

      let lastPath = null;
      const sweep = () => {
        const id = videoID();
        const homeKey = location.pathname === "/" ? "home" : null;
        const watchKey = id && "watch:" + id;
        const listenKey = id && "listen:" + id;
        const relatedKey = id && "related:" + id;
        const root = document.documentElement;
        // Switched off: countdowns in progress stop, so none can start a
        // video later.
        if (!settings()) counting.clear();

        const path = location.pathname + "?" + (id || "");
        if (path !== lastPath) {
          // A new page: home locks again, and countdowns for other pages
          // stop. Video unlocks are kept, so going back to a video you
          // opened doesn't ask again.
          lastPath = path;
          if (!homeKey) unlocked.delete("home");
          for (const key of counting.keys()) {
            if (![homeKey, watchKey, listenKey, relatedKey].includes(key)) counting.delete(key);
          }
        }

        root.classList.toggle("orca-lock-home", isLocked(homeKey));
        if (isLocked(homeKey)) {
          const element = card("orca-bump-home", "Recommendations are hidden.",
                               [{ label: "Show recommendations", key: homeKey }]);
          if (!element.isConnected) document.body?.appendChild(element);
        } else {
          remove("orca-bump-home");
        }

        // The picture stays covered until the video is opened for watching;
        // opened for listening, the cover offers watching instead.
        const player = document.getElementById("player-container-id");
        if (isLocked(watchKey) && player) {
          const listening = !isLocked(listenKey);
          // The cover hides YouTube's own play button, so listening gets
          // one. It also starts the audio if the page wouldn't without a tap.
          const video = document.querySelector("#player-container-id video");
          const element = listening
            ? card("orca-bump-player", "Listening only.", [
                { label: video && !video.paused ? "Pause" : "Play",
                  run: () => video && (video.paused ? video.play().catch(() => {}) : video.pause()) },
                { label: "Watch video", key: watchKey },
              ])
            : card("orca-bump-player", "Here for this video?", [
                { label: "Watch video", key: watchKey },
                { label: "Listen only", key: listenKey },
              ]);
          if (element.parentElement !== player) player.appendChild(element);
          for (const video of document.querySelectorAll("video")) {
            if (!listening && !video.paused) video.pause();
            keepInline(video);
          }
        } else {
          remove("orca-bump-player");
        }

        const related = document.querySelector(".related-items-container");
        root.classList.toggle("orca-lock-related", isLocked(relatedKey));
        if (isLocked(relatedKey) && related) {
          const element = card("orca-bump-related", "More videos are hidden.",
                               [{ label: "Show more videos", key: relatedKey }]);
          if (element.nextElementSibling !== related) related.before(element);
        } else {
          remove("orca-bump-related");
        }
      };

      // The countdowns, which wait while the page is off screen. The sweep
      // runs every second regardless, so the lengths on the buttons follow
      // the night hours, and a listening video is put back in the page.
      setInterval(() => {
        // Drop the last page's countdowns before any of them can unlock.
        sweep();
        for (const [key, left] of isOnScreen() ? counting : []) {
          if (left > 1) {
            counting.set(key, left - 1);
          } else {
            counting.delete(key);
            unlock(key);
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

    /// The user script for a new web view. It starts with the current
    /// settings, or nil when switched off.
    static func userScript(_ settings: Settings?) -> WKUserScript {
        WKUserScript(
            source: "if (window.__orcaSpeedBumps === undefined) { \(setScript(settings)) }" + script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: world
        )
    }

    /// JavaScript that changes the settings in a page that is already open.
    /// Run it in `world`. The web view's user script keeps the settings it
    /// was made with, so the app also runs this as each new page starts.
    static func setScript(_ settings: Settings?) -> String {
        let json = settings.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        return "window.__orcaSpeedBumps = \(json ?? "null"); window.__applyOrcaSpeedBumps && window.__applyOrcaSpeedBumps();"
    }

    /// JavaScript that tells the page whether you can see it. Run it in `world`.
    static func onScreenScript(_ onScreen: Bool) -> String {
        "window.__orcaOnScreen = \(onScreen);"
    }
}
