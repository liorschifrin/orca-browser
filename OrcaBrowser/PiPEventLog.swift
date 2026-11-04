import WebKit

/// TEMPORARY: copies the page's short video event log to
/// Documents/pipevents.log when the app comes forward, so a misbehaving
/// picture in picture return can be read off the phone. Delete afterwards.
enum PiPEventLog {
    static func dump(from webView: WKWebView?) {
        webView?.evaluateJavaScript("(window.__orcaEvents || []).join('\\n')") { result, _ in
            guard let text = result as? String, !text.isEmpty,
                  let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let entry = Data(("--- \(Date().formatted(.iso8601))\n" + text + "\n").utf8)
            let url = dir.appendingPathComponent("pipevents.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(entry); try? handle.close()
            } else {
                try? entry.write(to: url)
            }
        }
    }
}
