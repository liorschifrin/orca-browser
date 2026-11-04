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

    /// The quality choice that leaves it to the player.
    nonisolated static let autoQuality = "auto"

    /// What YouTube calls a quality level, as people write it.
    static func qualityName(_ level: String) -> String {
        switch level {
        case "tiny": "144p"
        case "small": "240p"
        case "medium": "360p"
        case "large": "480p"
        case "hd720": "720p"
        case "hd1080": "1080p"
        case "hd1440": "1440p"
        case "hd2160": "4K"
        case "hd2880": "5K"
        case "highres": "8K"
        default: level
        }
    }

    struct State: Equatable {
        /// There's a watch page video to control.
        var isAvailable = false
        var isPaused = true
        var rate = 1.0
        /// The video has captions to turn on.
        var hasCaptions = false
        var captionsOn = false
        /// The quality levels the video has, lowest first, and the one
        /// chosen (`autoQuality` when the player decides).
        var qualities: [String] = []
        var quality = PlaybackControl.autoQuality
        /// The quality actually playing, which is what Auto has picked.
        var playingQuality: String?

        init() {}

        init?(message body: Any) {
            guard let body = body as? [String: Any], let available = body["available"] as? Bool else { return nil }
            isAvailable = available
            isPaused = body["paused"] as? Bool ?? true
            rate = body["rate"] as? Double ?? 1
            hasCaptions = body["hasCaptions"] as? Bool ?? false
            captionsOn = body["captionsOn"] as? Bool ?? false
            qualities = body["qualities"] as? [String] ?? []
            quality = body["quality"] as? String ?? PlaybackControl.autoQuality
            playingQuality = body["playingQuality"] as? String
        }
    }

    enum Command {
        case seek(seconds: Double)
        case togglePlay
        case setRate(Double)
        case toggleCaptions
        case setQuality(String)
        case pictureInPicture
        case fullscreen

        var script: String {
            switch self {
            case .seek(let seconds): "window.__orcaPlayback?.seek(\(seconds))"
            case .togglePlay: "window.__orcaPlayback?.togglePlay()"
            case .setRate(let rate): "window.__orcaPlayback?.setRate(\(rate))"
            case .toggleCaptions: "window.__orcaPlayback?.toggleCaptions()"
            case .setQuality(let quality): "window.__orcaPlayback?.setQuality(\"\(quality)\")"
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

      // YouTube's player object has methods for captions. The mobile site
      // is the same player as the desktop one.
      const ytPlayer = () =>
        document.getElementById('movie_player') || document.querySelector('.html5-video-player');
      // Lowest first.
      const QUALITY_ORDER = ['tiny', 'small', 'medium', 'large', 'hd720', 'hd1080',
                             'hd1440', 'hd2160', 'hd2880', 'highres'];
      let chosenQuality = null;
      const qualityState = () => {
        try {
          const levels = (ytPlayer()?.getAvailableQualityLevels?.() || [])
            .filter(level => QUALITY_ORDER.includes(level))
            .sort((a, b) => QUALITY_ORDER.indexOf(a) - QUALITY_ORDER.indexOf(b));
          const playing = ytPlayer()?.getPlaybackQuality?.();
          return { qualities: levels, quality: chosenQuality || 'auto',
                   playingQuality: QUALITY_ORDER.includes(playing) ? playing : null };
        } catch (e) { return { qualities: [], quality: 'auto', playingQuality: null }; }
      };
      const applyQuality = quality => {
        const player = ytPlayer();
        if (!player) return;
        try {
          if (quality) {
            player.setPlaybackQualityRange?.(quality, quality);
            player.setPlaybackQuality?.(quality);
          } else {
            // Any quality, so the player picks as it does by default.
            player.setPlaybackQualityRange?.('tiny', 'highres');
          }
        } catch (e) {}
      };
      const captionState = () => {
        const player = ytPlayer();
        if (!player) return { hasCaptions: false, captionsOn: false };
        try {
          const tracks = player.getOption?.('captions', 'tracklist');
          const track = player.getOption?.('captions', 'track');
          return {
            // Until the captions module answers, assume there are some.
            hasCaptions: Array.isArray(tracks) ? tracks.length > 0 : true,
            captionsOn: !!player.isSubtitlesOn?.() || !!(track && track.languageCode),
          };
        } catch (e) { return { hasCaptions: false, captionsOn: false }; }
      };

      const report = () => {
        const video = isWatchPage() ? mainVideo() : null;
        if (video && !watched.has(video)) {
          watched.add(video);
          const reapply = () => setTimeout(() => {
            if (chosenRate !== null && video.playbackRate !== chosenRate) video.playbackRate = chosenRate;
            if (chosenQuality) applyQuality(chosenQuality);
          }, 0);
          video.addEventListener('loadstart', reapply);
          video.addEventListener('loadedmetadata', reapply);
          for (const type of ['play', 'pause', 'ratechange']) video.addEventListener(type, report);
          try { ytPlayer()?.loadModule?.('captions'); } catch (e) {}
        }
        const state = video
          ? { available: true, paused: video.paused, rate: video.playbackRate, ...captionState(), ...qualityState() }
          : { available: false, paused: true, rate: 1, hasCaptions: false, captionsOn: false,
              qualities: [], quality: 'auto', playingQuality: null };
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
        // Tries YouTube's toggle, then choosing a caption track directly, then
        // pressing its own CC button, stopping as soon as captions change.
        toggleCaptions: () => withVideo(() => {
          const player = ytPlayer();
          if (!player) return;
          const note = window.__orcaNote || (() => {});
          const isOn = () => captionState().captionsOn;
          const wasOn = isOn();
          note('captions: was ' + wasOn + '; ' + ['toggleSubtitles', 'toggleSubtitlesOn', 'isSubtitlesOn', 'setOption', 'getOption', 'loadModule']
            .map(name => name + ' ' + typeof player[name]).join(', ')
            + '; tracks ' + JSON.stringify(player.getOption?.('captions', 'tracklist'))?.slice(0, 120));
          const attempts = [
            // Pick a caption track directly (or an empty one to turn captions off).
            () => {
              player.loadModule?.('captions');
              if (wasOn) { player.setOption?.('captions', 'track', {}); return; }
              const tracks = player.getOption?.('captions', 'tracklist') || [];
              const language = (navigator.language || 'en').split('-')[0];
              const track = tracks.find(t => t.languageCode === language) || tracks[0];
              if (track) player.setOption?.('captions', 'track', track);
            },
            () => wasOn ? player.toggleSubtitles?.() : (player.toggleSubtitlesOn || player.toggleSubtitles)?.call(player),
            () => document.querySelector('.ytp-subtitles-button, button[aria-label*="aption"], button[aria-label*="ubtitle"]')?.click(),
          ];
          let next = 0;
          const step = () => {
            if (isOn() !== wasOn || next >= attempts.length) { note('captions: now ' + isOn()); report(); return; }
            note('captions: attempt ' + next);
            try { attempts[next]?.(); } catch (e) { note('captions error: ' + e); }
            next += 1;
            setTimeout(step, 400);
          };
          step();
        }),
        setQuality: quality => withVideo(() => {
          chosenQuality = quality === 'auto' ? null : quality;
          applyQuality(chosenQuality);
          (window.__orcaNote || (() => {}))('quality -> ' + quality + ' (levels: ' + qualityState().qualities.join(',') + ')');
        }),
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
