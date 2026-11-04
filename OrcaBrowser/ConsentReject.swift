import Foundation
import OSLog
import WebKit

/// Says "no" to cookie consent on the page's behalf, for the consent platforms
/// that offer a plain reject. This is the script half of cookie banner
/// handling; `CookieBanners` hides what is left on screen.
///
/// It costs almost nothing on pages without a banner. A small script runs in
/// every frame, but a frame that isn't a consent message does one URL test and
/// stops, and the page itself looks for a known banner every half second for
/// twelve seconds. Only when a banner shows up does it ask the app whether
/// rejecting is switched on for this site, so the per-site and global switches
/// are read at that moment, not baked into the page.
///
/// Platforms change their markup, so this needs upkeep. Only Fides, OneTrust,
/// Sourcepoint and Google have been checked against real pages; the others use the
/// selectors their documentation gives.
enum ConsentReject {
    static let handlerName = "orcaConsent"

    /// The script, for every frame of every page.
    static let userScript = WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: false)

    private static let script = """
    (() => {
      if (window.__orcaConsentReject) return;
      window.__orcaConsentReject = true;
      const isSourcepointMessage = /[?&]message_id=\\d/.test(location.href) && window !== window.top;
      // Not a consent message, and not the page itself: nothing to look for.
      if (window !== window.top && !isSourcepointMessage) return;

      const click = selector => {
        const button = document.querySelector(selector);
        if (button) button.click();
        return !!button;
      };
      // Sourcepoint shows its message in a frame of its own. Only a button that
      // plainly says no counts: "Reject all and subscribe" is a purchase.
      // textContent, not innerText: the message is hidden, and hidden text is empty.
      const noText = /^(reject all|reject|decline|decline all|i do not agree|do not accept|refuse|refuse all|alle ablehnen|ablehnen|tout refuser|refuser)$/i;
      const noButton = () => [...document.querySelectorAll("button")].find(b => noText.test((b.textContent || "").trim()));

      // A banner to look for, whether its way of saying no is ready yet, and
      // how to do it (returns whether it could).
      const platforms = [
        { name: "fides", present: "#fides-banner",
          ready: () => document.querySelector("#fides-reject-all-button"), reject: () => click("#fides-reject-all-button") },
        { name: "onetrust", present: "#onetrust-banner-sdk",
          ready: () => (window.OneTrust && window.OneTrust.RejectAll) || document.querySelector("#onetrust-reject-all-handler, .ot-pc-refuse-all-handler"),
          reject: () => {
            if (window.OneTrust && typeof window.OneTrust.RejectAll === "function") { window.OneTrust.RejectAll(); return true; }
            return click("#onetrust-reject-all-handler, .ot-pc-refuse-all-handler");
          } },
        // Google Search and its other pages. The button ids don't depend on the language.
        { name: "google", present: "#xe7COe",
          ready: () => document.querySelector("#W0wltc"), reject: () => click("#W0wltc") },
        { name: "didomi", present: "#didomi-host",
          ready: () => document.querySelector("#didomi-notice-disagree-button"), reject: () => click("#didomi-notice-disagree-button") },
        { name: "cookiebot", present: "#CybotCookiebotDialog",
          ready: () => document.querySelector("#CybotCookiebotDialogBodyButtonDecline, #CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll"),
          reject: () => click("#CybotCookiebotDialogBodyButtonDecline, #CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll") },
        { name: "complianz", present: ".cmplz-cookiebanner",
          ready: () => document.querySelector(".cmplz-deny"), reject: () => click(".cmplz-deny") },
        { name: "cookieyes", present: ".cky-consent-container",
          ready: () => document.querySelector(".cky-btn-reject"), reject: () => click(".cky-btn-reject") },
        { name: "iubenda", present: "#iubenda-cs-banner",
          ready: () => document.querySelector(".iubenda-cs-reject-btn"), reject: () => click(".iubenda-cs-reject-btn") },
        { name: "osano", present: ".osano-cm-window",
          ready: () => document.querySelector(".osano-cm-denyAll"), reject: () => click(".osano-cm-denyAll") },
      ];
      const sourcepoint = {
        name: "sourcepoint", present: "body",
        ready: noButton,
        reject: () => { const button = noButton(); if (button) button.click(); return !!button; }
      };
      const candidates = isSourcepointMessage ? [sourcepoint] : platforms;

      const tryReject = async (platform) => {
        let allowed = false;
        try { allowed = await window.webkit.messageHandlers.\(handlerName).postMessage(platform.name); } catch (e) {}
        if (allowed && platform.reject()) window.webkit.messageHandlers.\(handlerName).postMessage("rejected:" + platform.name);
      };
      // Look twice a second for twelve seconds: banners are drawn after load.
      let checks = 0;
      const timer = setInterval(() => {
        if (++checks > 24) { clearInterval(timer); return; }
        const platform = candidates.find(p => document.querySelector(p.present) && p.ready());
        if (!platform) return;
        clearInterval(timer);
        tryReject(platform);
      }, 500);
    })();
    """

    /// Answers the script's question: may it reject on the page showing now?
    /// Held by the web view, so it must not hold anything that holds the web view.
    final class Handler: NSObject, WKScriptMessageHandlerWithReply {
        private let isAllowed: (WKScriptMessage) -> Bool
        private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OrcaBrowser", category: "ConsentReject")

        init(isAllowed: @escaping (WKScriptMessage) -> Bool) { self.isAllowed = isAllowed }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            if let text = message.body as? String, text.hasPrefix("rejected:") {
                log.info("Rejected consent: \(text.dropFirst("rejected:".count)) on \(message.webView?.url?.host() ?? "?")")
                replyHandler(true, nil)
            } else {
                replyHandler(isAllowed(message), nil)
            }
        }
    }

    static func install(on controller: WKUserContentController, isAllowed: @escaping (WKScriptMessage) -> Bool) {
        controller.addUserScript(userScript)
        controller.addScriptMessageHandler(Handler(isAllowed: isAllowed), contentWorld: .page, name: handlerName)
    }
}
