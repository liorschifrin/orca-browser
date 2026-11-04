import WebKit

/// Changes to the bar at the top of YouTube pages: hides the "Open App"
/// button, and on watch pages puts the time ("1:23 / 12:34") and a chapters
/// button just after the logo.
///
/// The button and the logo are found by their text and position rather than
/// by class names, which YouTube changes often. If the logo isn't found, the
/// time and button sit where Open App was, or before search, and if neither
/// is found they aren't shown. Only the top-level YouTube page, in English.
/// Each part follows its setting (`window.__orcaHeader`), which the app can
/// change while the page is open.
enum YouTubeHeader {
    /// The chapters button reports here; the app shows the list.
    nonisolated static let chaptersMessageName = "orcaChapters"

    static func userScript(hidesOpenApp: Bool, showsTools: Bool) -> WKUserScript {
        WKUserScript(source: settingsScript(hidesOpenApp: hidesOpenApp, showsTools: showsTools) + source,
                     injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    /// JavaScript that changes the settings in a page that is already open.
    static func settingsScript(hidesOpenApp: Bool, showsTools: Bool) -> String {
        "window.__orcaHeader = { hidesOpenApp: \(hidesOpenApp), showsTools: \(showsTools) };"
    }

    static let source = """
    (() => {
      if (!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;

      const header = () => document.querySelector('ytm-mobile-topbar-renderer') || document.querySelector('header');
      const isWatchPage = () => location.pathname === '/watch';
      const mainVideo = () =>
        document.querySelector('.player-container video.html5-main-video') ||
        document.querySelector('.player-container video');

      const style = document.createElement('style');
      style.textContent = `
        #orca-time {
          flex: none; margin: 0 0 0 8px; white-space: nowrap;
          font: 500 12px -apple-system, sans-serif; font-variant-numeric: tabular-nums;
          color: var(--yt-spec-text-secondary, #aaa);
        }
        /* Sits after the time; the script then slides it to the middle of
           the gap between the time and search. */
        #orca-chapters {
          flex: none; margin: 0 0 0 4px; display: flex; align-items: center; justify-content: center;
          width: 30px; height: 30px; padding: 0; border: 0; background: none;
          color: var(--yt-spec-text-secondary, #aaa); -webkit-tap-highlight-color: transparent;
        }
        /* A video with no chapters: the button is dimmed and does nothing. */
        #orca-chapters[data-empty] { opacity: 0.3; }
      `;
      (document.head || document.documentElement).appendChild(style);

      const findOpenApp = bar => {
        for (const element of bar.querySelectorAll('ytm-button-renderer, a, button, [role="button"]')) {
          const text = (element.textContent || element.getAttribute('aria-label') || '').trim();
          if (/^open app$/i.test(text)) return element.closest('ytm-button-renderer') || element;
        }
        return null;
      };
      // The search button you can see; the search box has hidden ones too.
      const findSearch = bar =>
        [...bar.querySelectorAll('button[aria-label*="earch"], a[aria-label*="earch"]')]
          .find(element => element.getBoundingClientRect().width > 0) || null;
      const findLogo = bar =>
        bar.querySelector('ytm-home-logo, a[href="/"], a[aria-label*="YouTube Home"], [class*="logo"]');

      // The element in `row` that holds `node`.
      const childOf = (row, node) => {
        while (node && node.parentElement !== row) node = node.parentElement;
        return node;
      };
      const commonRow = (a, b) => {
        for (let element = a.parentElement; element; element = element.parentElement) {
          if (element.contains(b)) return element;
        }
        return null;
      };

      let timeLabel = null;
      let chaptersButton = null;
      let hiddenOpenApp = null;

      const clock = seconds => {
        const whole = Math.floor(seconds);
        const hours = Math.floor(whole / 3600);
        const minutes = Math.floor(whole % 3600 / 60);
        const rest = String(whole % 60).padStart(2, '0');
        return hours ? hours + ':' + String(minutes).padStart(2, '0') + ':' + rest : minutes + ':' + rest;
      };

      const makeTools = () => {
        timeLabel = document.createElement('span');
        timeLabel.id = 'orca-time';
        chaptersButton = document.createElement('button');
        chaptersButton.id = 'orca-chapters';
        chaptersButton.type = 'button';
        chaptersButton.setAttribute('aria-label', 'Chapters');
        const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('width', '20');
        svg.setAttribute('height', '20');
        svg.setAttribute('fill', 'currentColor');
        const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        path.setAttribute('d', 'M3 13h2v-2H3v2zm0 4h2v-2H3v2zm0-8h2V7H3v2zm4 4h14v-2H7v2zm0 4h14v-2H7v2zM7 7v2h14V7H7z');
        svg.appendChild(path);
        chaptersButton.appendChild(svg);
        chaptersButton.addEventListener('click', () => {
          if (!(window.__orcaChapters?.() || []).length) return;
          window.webkit?.messageHandlers?.\(chaptersMessageName)?.postMessage({});
        });
      };

      // Halfway between the right edge of the time and the left edge of
      // search, whatever the header's own layout does with the free space.
      // The shift is a transform, so it doesn't change the layout, and the
      // button's natural position is what's left after taking it off.
      let shift = 0;
      const centerChaptersButton = bar => {
        const search = findSearch(bar);
        if (!search) return;
        const time = timeLabel.getBoundingClientRect();
        // The search icon itself, not the button's (wider) touch area.
        const glyph = search.querySelector('svg, yt-icon, img');
        const end = (glyph && glyph.getBoundingClientRect().width > 0 ? glyph : search).getBoundingClientRect();
        const own = chaptersButton.getBoundingClientRect();
        if (!own.width || !time.width || !end.width || end.left <= time.right) return;
        const wanted = (time.right + end.left) / 2 - (own.left - shift + own.width / 2);
        if (Math.abs(wanted - shift) < 0.5) return;
        shift = wanted;
        chaptersButton.style.transform = 'translateX(' + shift + 'px)';
      };

      const isPlaced = () => timeLabel.isConnected && chaptersButton.isConnected;
      // The time, then the button, in that order, at `row` before `before`.
      const insertPair = (row, before) => {
        row.insertBefore(timeLabel, before);
        row.insertBefore(chaptersButton, timeLabel.nextSibling);
      };

      const place = (bar, openApp) => {
        const logo = findLogo(bar);
        const search = findSearch(bar);
        if (logo && search) {
          const row = commonRow(logo, search);
          const top = row && childOf(row, logo);
          if (top) { insertPair(row, top.nextSibling); return true; }
        }
        const anchor = openApp || search;
        if (anchor && anchor.parentNode) { insertPair(anchor.parentNode, anchor); return true; }
        return false;
      };

      const update = () => {
        const bar = header();
        if (!bar) return;
        const options = window.__orcaHeader || { hidesOpenApp: true, showsTools: true };

        const openApp = findOpenApp(bar);
        if (openApp && options.hidesOpenApp) {
          openApp.style.setProperty('display', 'none', 'important');
          hiddenOpenApp = openApp;
        } else if (hiddenOpenApp) {
          hiddenOpenApp.style.removeProperty('display');
          hiddenOpenApp = null;
        }

        const video = isWatchPage() ? mainVideo() : null;
        const visible = options.showsTools && video && isFinite(video.currentTime);
        if (!visible) {
          if (timeLabel) { timeLabel.style.display = 'none'; chaptersButton.style.display = 'none'; }
          return;
        }
        if (!timeLabel) makeTools();
        if (!isPlaced() && !place(bar, openApp)) return;
        timeLabel.style.display = '';
        chaptersButton.style.display = '';
        const text = isFinite(video.duration)
          ? clock(video.currentTime) + ' / ' + clock(video.duration)
          : 'LIVE';
        if (timeLabel.textContent !== text) timeLabel.textContent = text;
        const hasChapters = (window.__orcaChapters?.() || []).length > 0;
        chaptersButton.toggleAttribute('data-empty', !hasChapters);
        centerChaptersButton(bar);
      };

      setInterval(update, 250);
    })();
    """
}
