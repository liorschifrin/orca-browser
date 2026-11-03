import WebKit

/// THROWAWAY: writes the layout of the YouTube player and what sits around it
/// to Documents/domdump.log whenever the app leaves the foreground, so the
/// toolbar's placement can be fixed against the real page. Delete afterwards.
enum DomDump {
    private static let script = """
    (() => {
      const round = n => Math.round(n);
      const d = el => {
        const cs = getComputedStyle(el), r = el.getBoundingClientRect();
        return { tag: el.tagName.toLowerCase(), id: el.id, cls: String(el.className).slice(0, 100),
                 pos: cs.position, top: cs.top, oy: cs.overflowY, tf: cs.transform === 'none' ? '' : cs.transform,
                 mb: cs.marginBottom, pb: cs.paddingBottom, pt: cs.paddingTop,
                 r: [round(r.left), round(r.top), round(r.width), round(r.height)] };
      };
      const out = { url: location.href, scrollY: round(scrollY), innerH: innerHeight,
        vv: visualViewport && [round(visualViewport.offsetTop), round(visualViewport.height)],
        body: [...document.body.attributes].map(a => a.name + '=' + a.value).slice(0, 10) };
      const pc = document.querySelector('.player-container');
      out.player = pc && d(pc);
      out.ancestors = [];
      for (let e = pc && pc.parentElement; e && e !== document.documentElement; e = e.parentElement) {
        out.ancestors.push(d(e));
      }
      const parent = pc && pc.parentElement;
      out.siblings = parent ? [...parent.children].slice(0, 14).map(d) : [];
      out.placeholder = [...document.querySelectorAll('[class*="placeholder"]')].slice(0, 4).map(d);
      const pb = pc ? pc.getBoundingClientRect().bottom : 100;
      out.below = [4, 30, 70].map(dy => document.elementsFromPoint(innerWidth / 2, pb + dy).slice(0, 5).map(d));
      const bar = document.getElementById('orca-playback-toolbar');
      out.bar = bar && d(bar);
      out.scrollers = [...document.querySelectorAll('*')].filter(e => {
        const o = getComputedStyle(e).overflowY;
        return (o === 'auto' || o === 'scroll') && e.scrollHeight > e.clientHeight + 2;
      }).slice(0, 6).map(e => Object.assign(d(e), { sh: e.scrollHeight, st: round(e.scrollTop) }));
      return JSON.stringify(out);
    })()
    """

    static func run(on webView: WKWebView?) {
        webView?.evaluateJavaScript(script) { result, error in
            let text = (result as? String) ?? "error: \(String(describing: error))"
            guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let url = dir.appendingPathComponent("domdump.log")
            let line = Data((text + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(line); try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}
