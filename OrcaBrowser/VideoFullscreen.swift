import UIKit
import WebKit

/// Lets a fullscreen video turn sideways on the iPhone.
///
/// The iPhone app is portrait only, which the fullscreen video player has to
/// fight: it turned to landscape, then fell back to portrait at the slightest
/// tilt. Instead the app allows landscape while a page reports a video in
/// fullscreen, and asks for portrait again when the last one closes.
enum VideoFullscreen {
    /// The script message handler pages report fullscreen changes to.
    nonisolated static let messageName = "orcaVideoFullscreen"

    /// Web views with a video in fullscreen right now.
    private static var active: Set<ObjectIdentifier> = []

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart,
                     forMainFrameOnly: false, in: .page)
    }

    // The fullscreen events don't bubble, so these listen while they travel
    // down from the window, before the page sees them.
    static let source = """
    (() => {
      const tell = active => window.webkit?.messageHandlers?.\(messageName)?.postMessage({ active });
      window.addEventListener('webkitbeginfullscreen', () => tell(true), true);
      window.addEventListener('webkitendfullscreen', () => tell(false), true);
      document.addEventListener('fullscreenchange', () => tell(!!document.fullscreenElement), true);
      document.addEventListener('webkitfullscreenchange', () => tell(!!document.webkitFullscreenElement), true);
    })();
    """

    /// What the app allows: everything on the iPad, and on the iPhone portrait
    /// unless a video is fullscreen.
    static var supportedOrientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return active.isEmpty ? .portrait : .allButUpsideDown
    }

    static func changed(_ webView: WKWebView, active isActive: Bool) {
        let wasActive = !active.isEmpty
        if isActive { active.insert(ObjectIdentifier(webView)) } else { active.remove(ObjectIdentifier(webView)) }
        if wasActive != !active.isEmpty { applyOrientations() }
    }

    /// For a web view going away, which can't report the end of its fullscreen.
    static func forget(_ webView: WKWebView) {
        changed(webView, active: false)
    }

    private static func applyOrientations() {
        let mask = supportedOrientations
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if mask == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }

    /// Answers UIKit's question of which way the app may turn.
    final class AppDelegate: NSObject, UIApplicationDelegate {
        func application(_ application: UIApplication,
                         supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
            VideoFullscreen.supportedOrientations
        }
    }
}
