import WebKit

/// Playback controls for the video on YouTube watch pages.
///
/// A user script in the page reports whether there's a watch page video and
/// whether it's playing, and at what speed (`State`), and offers the controls
/// the native `PlaybackBar` calls (`Command`). The bar is native, above the
/// bottom bar, and the page is made shorter to leave room for it.
///
/// The controls run when you tap the native bar. WebKit starts picture in
/// picture and fullscreen only for a tap, and calls the app makes with no tap
/// (leaving the app, say) are refused.
///
/// Only the top-level page, and only `/watch` pages: Shorts and embedded
/// players don't get a bar. YouTube changes its markup often, so the video
/// lookup may need updating.
enum PlaybackControl {
    /// The page reports here.
    nonisolated static let messageName = "orcaPlayback"

    struct State: Equatable {
        /// There's a watch page video to control.
        var isAvailable = false
        var isPaused = true
        var rate = 1.0

        init() {}

        init?(message body: Any) {
            guard let body = body as? [String: Any], let available = body["available"] as? Bool else { return nil }
            isAvailable = available
            isPaused = body["paused"] as? Bool ?? true
            rate = body["rate"] as? Double ?? 1
        }
    }

    enum Command {
        case seek(seconds: Double)
        case togglePlay
        case setRate(Double)
        case pictureInPicture
        case fullscreen

        var script: String {
            switch self {
            case .seek(let seconds): "window.__orcaPlayback?.seek(\(seconds))"
            case .togglePlay: "window.__orcaPlayback?.togglePlay()"
            case .setRate(let rate): "window.__orcaPlayback?.setRate(\(rate))"
            case .pictureInPicture: "window.__orcaPlayback?.pictureInPicture()"
            case .fullscreen: "window.__orcaPlayback?.fullscreen()"
            }
        }
    }

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart,
                     forMainFrameOnly: true, in: .page)
    }

    private static let source = """
    (() => {
      if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;

      const isWatchPage = () => location.pathname === '/watch';
      const mainVideo = () =>
        document.querySelector('.player-container video.html5-main-video') ||
        document.querySelector('.player-container video');

      // The speed picked in the app, kept for the next video: YouTube resets
      // it whenever a video loads.
      let chosenRate = null;
      let lastReport = '';
      const watched = new WeakSet();

      const report = () => {
        const video = isWatchPage() ? mainVideo() : null;
        if (video && !watched.has(video)) {
          watched.add(video);
          const reapply = () => setTimeout(() => {
            if (chosenRate !== null && video.playbackRate !== chosenRate) video.playbackRate = chosenRate;
          }, 0);
          video.addEventListener('loadstart', reapply);
          video.addEventListener('loadedmetadata', reapply);
          for (const type of ['play', 'pause', 'ratechange']) video.addEventListener(type, report);
        }
        const state = video
          ? { available: true, paused: video.paused, rate: video.playbackRate }
          : { available: false, paused: true, rate: 1 };
        const text = JSON.stringify(state);
        if (text === lastReport) return;
        lastReport = text;
        window.webkit?.messageHandlers?.\(messageName)?.postMessage(state);
      };

      const withVideo = action => {
        const video = mainVideo();
        if (!video) return;
        try { action(video); } catch (e) {}
        report();
      };

      window.__orcaPlayback = {
        seek: seconds => withVideo(video => {
          const end = isFinite(video.duration) ? video.duration : Infinity;
          video.currentTime = Math.max(0, Math.min(end, video.currentTime + seconds));
        }),
        togglePlay: () => withVideo(video => { video.paused ? video.play() : video.pause(); }),
        setRate: rate => withVideo(video => { chosenRate = rate; video.playbackRate = rate; }),
        pictureInPicture: () => withVideo(video => {
          if (video.webkitSupportsPresentationMode?.('picture-in-picture')) {
            video.webkitSetPresentationMode('picture-in-picture');
          }
        }),
        fullscreen: () => withVideo(video => { video.webkitEnterFullscreen(); }),
      };

      // The site changes pages without reloading, so check on a timer too.
      setInterval(report, 500);
    })();
    """
}
