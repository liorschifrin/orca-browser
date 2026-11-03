import WebKit

/// A toolbar of playback controls under the video on YouTube watch pages:
/// back 10 seconds, play/pause, forward 10 seconds, three speeds, picture in
/// picture, and fullscreen.
///
/// It's an element in the page rather than native UI, for two reasons. A tap
/// on it is a real tap on the page, which is what WebKit requires before it
/// starts picture in picture or fullscreen (calls from the app are refused),
/// and it can sit directly under the sticky player and follow it.
///
/// The mobile site's player (`.player-container`) is fixed to the top of the
/// screen while you scroll, with a placeholder reserving its space in the
/// page. The toolbar is fixed just below the player's bottom edge, and the
/// placeholder gets that much extra space so the page's content starts below
/// the toolbar instead of under it. Only on watch pages in the top-level
/// page; Shorts and embedded players don't get one. YouTube changes its
/// markup often, so these names may need updating.
enum PlaybackToolbar {
    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart,
                     forMainFrameOnly: true, in: .page)
    }

    private static let source = """
    (() => {
      if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;

      const BAR_HEIGHT = 44;
      const SPEEDS = [0.5, 1, 2, 3];
      let bar = null;
      let buttons = {};
      let spacer = null;
      // The speed picked on the toolbar, kept for the next video: YouTube
      // resets it whenever a video loads.
      let chosenRate = null;
      const watched = new WeakSet();

      const isWatchPage = () => location.pathname === '/watch';
      const playerContainer = () => document.querySelector('.player-container');
      const mainVideo = () =>
        document.querySelector('.player-container video.html5-main-video') ||
        document.querySelector('.player-container video');

      const style = document.createElement('style');
      style.textContent = `
        #orca-playback-toolbar {
          position: fixed; left: 0; right: 0; z-index: 2147483000;
          box-sizing: border-box; height: ${BAR_HEIGHT}px; padding: 5px 6px;
          display: none; align-items: center; gap: 4px;
          background: rgba(20, 20, 20, 0.97); color: #fff;
          font: 600 12px -apple-system, sans-serif;
          -webkit-user-select: none; user-select: none;
          -webkit-tap-highlight-color: transparent; touch-action: none;
        }
        #orca-playback-toolbar button {
          flex: 1 1 0; min-width: 0; height: 34px; padding: 0; border: 0;
          border-radius: 8px; background: rgba(255, 255, 255, 0.14);
          color: #fff; font: inherit;
          display: flex; align-items: center; justify-content: center;
        }
        #orca-playback-toolbar svg { display: block; }
        #orca-playback-toolbar button.on { background: #fff; color: #000; }
      `;
      (document.head || document.documentElement).appendChild(style);

      // Icons are built node by node: the page doesn't allow setting HTML.
      const ICONS = {
        play: 'M8 5v14l11-7z',
        pause: 'M6 5h4v14H6zM14 5h4v14h-4z',
        pip: 'M19 7h-8v6h8V7zm2-4H3c-1.1 0-2 .9-2 2v14c0 1.1.9 1.98 2 1.98h18c1.1 0 2-.88 2-1.98V5c0-1.1-.9-2-2-2zm0 16.01H3V4.98h18v14.03z',
        fullscreen: 'M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z',
      };
      const setIcon = (button, name) => {
        if (button.dataset.icon === name) return;
        button.dataset.icon = name;
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('width', '22');
        svg.setAttribute('height', '22');
        svg.setAttribute('fill', 'currentColor');
        const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        path.setAttribute('d', ICONS[name]);
        svg.appendChild(path);
        button.replaceChildren(svg);
      };

      const withVideo = action => () => {
        const video = mainVideo();
        if (video) { try { action(video); } catch (e) {} }
        schedule();
      };
      const seek = seconds => withVideo(video => {
        const end = isFinite(video.duration) ? video.duration : Infinity;
        video.currentTime = Math.max(0, Math.min(end, video.currentTime + seconds));
      });

      const buttonSpecs = [
        ['back', '\\u221210', seek(-10)],
        ['play', {icon: 'play'}, withVideo(video => { video.paused ? video.play() : video.pause(); })],
        ['forward', '+10', seek(10)],
        ...SPEEDS.map(rate => ['rate' + rate, rate + '\\u00D7', withVideo(video => {
          chosenRate = rate;
          video.playbackRate = rate;
        })]),
        ['pip', {icon: 'pip'}, withVideo(video => {
          if (video.webkitSupportsPresentationMode?.('picture-in-picture')) {
            video.webkitSetPresentationMode('picture-in-picture');
          }
        })],
        ['fullscreen', {icon: 'fullscreen'}, withVideo(video => { video.webkitEnterFullscreen(); })],
      ];

      const makeBar = () => {
        bar = document.createElement('div');
        bar.id = 'orca-playback-toolbar';
        for (const [name, label, action] of buttonSpecs) {
          const button = document.createElement('button');
          button.type = 'button';
          if (typeof label === 'string') button.textContent = label;
          else setIcon(button, label.icon);
          button.addEventListener('click', action);
          buttons[name] = button;
          bar.appendChild(button);
        }
        // Dragging on the toolbar must not scroll the page under it.
        bar.addEventListener('touchmove', event => event.preventDefault(), { passive: false });
        document.body.appendChild(bar);
      };

      // Space under the player so the page starts below the toolbar.
      const reserveSpace = extra => {
        const target = document.querySelector('.player-placeholder-wrapper');
        if (spacer && spacer !== target) spacer.style.marginBottom = '';
        spacer = target;
        if (spacer) spacer.style.marginBottom = extra ? BAR_HEIGHT + 'px' : '';
      };

      const hide = () => {
        if (bar) bar.style.display = 'none';
        reserveSpace(false);
      };

      const update = () => {
        const container = playerContainer();
        const video = mainVideo();
        if (!document.body || !isWatchPage() || !container || !video) return hide();
        const rect = container.getBoundingClientRect();
        // The player has scrolled away or isn't showing a picture yet.
        if (rect.height < 1 || rect.bottom <= 0 || rect.bottom > innerHeight - BAR_HEIGHT) return hide();

        if (!bar) makeBar();
        if (!watched.has(video)) {
          watched.add(video);
          const reapply = () => setTimeout(() => {
            if (chosenRate !== null && video.playbackRate !== chosenRate) video.playbackRate = chosenRate;
          }, 0);
          video.addEventListener('loadstart', reapply);
          video.addEventListener('loadedmetadata', reapply);
          for (const type of ['play', 'pause', 'ratechange']) video.addEventListener(type, schedule);
        }
        bar.style.display = 'flex';
        bar.style.top = Math.round(rect.bottom) + 'px';
        reserveSpace(true);

        setIcon(buttons.play, video.paused ? 'play' : 'pause');
        for (const rate of SPEEDS) {
          buttons['rate' + rate].classList.toggle('on', Math.abs(video.playbackRate - rate) < 0.01);
        }
      };

      let pending = false;
      function schedule() {
        if (pending) return;
        pending = true;
        requestAnimationFrame(() => { pending = false; update(); });
      }

      // The site changes pages without reloading, so check on a timer too.
      setInterval(schedule, 500);
      addEventListener('scroll', schedule, { passive: true, capture: true });
      addEventListener('resize', schedule);
      addEventListener('orientationchange', schedule);
    })();
    """
}
