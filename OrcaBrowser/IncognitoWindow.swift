import LocalAuthentication
import Observation
import UIKit
import WebKit

/// What the tabs of one incognito window share: a throwaway website data
/// store (so a login in one tab holds in the others) and the in-memory site
/// choices. Neither is ever written to disk.
final class PrivateSession {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let rules = PrivateSiteRules()

    /// Cookies, caches and storage all go; the session is not used again.
    func wipe() {
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
}

/// The incognito window: a space of its own beside the normal tabs. It
/// lives in memory only, so an app that is closed or killed has no trace of
/// it. The store shows it only after `BrowserStore.enterIncognito` has let
/// you in, and leaving it (to normal tabs, or by leaving the app) locks it.
@Observable
final class IncognitoWindow {
    var tabs: [Tab] = []
    var selectedTabID: Tab.ID
    private(set) var session: PrivateSession

    /// The clipboard's change count when the window was last entered; nil
    /// while nobody is inside it.
    @ObservationIgnored private var clipboardCountOnEntry: Int?

    init() {
        let session = PrivateSession()
        self.session = session
        let first = Tab(session: session)
        tabs = [first]
        selectedTabID = first.id
    }

    /// True once something has been opened: only then is there anything to
    /// protect or to continue with.
    var hasContent: Bool { tabs.contains { !$0.isBlank } }

    /// Closes every tab and forgets everything they stored.
    func close() {
        for tab in tabs { tab.teardown() }
        tabs = []
        session.wipe()
    }

    /// Closes everything and leaves one blank tab on a new session.
    func reset() {
        close()
        session = PrivateSession()
        let first = Tab(session: session)
        tabs = [first]
        selectedTabID = first.id
    }

    // MARK: Clipboard

    func didEnter(pasteboard: UIPasteboard = .general) {
        clipboardCountOnEntry = pasteboard.changeCount
    }

    /// Empties the clipboard if something was copied while inside. Anything
    /// copied before entering is left alone.
    func didLeave(pasteboard: UIPasteboard = .general) {
        guard let count = clipboardCountOnEntry else { return }
        clipboardCountOnEntry = nil
        guard pasteboard.changeCount != count else { return }
        pasteboard.items = []
        ClipboardCache.shared.clear()
    }
}

/// Asks the person holding the phone to prove it.
protocol IncognitoAuthenticating {
    /// Nil when allowed; otherwise a message saying why not. Cancelling
    /// returns an empty message, which needs no explanation.
    func authenticate() async -> String?
}

/// Face ID only: no passcode fallback.
struct FaceIDAuthenticator: IncognitoAuthenticating {
    func authenticate() async -> String? {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Face ID isn’t available, so your incognito tabs can’t be opened."
        }
        do {
            _ = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics, localizedReason: "Open your incognito tabs"
            )
            return nil
        } catch let error as LAError where error.code == .userCancel || error.code == .systemCancel
            || error.code == .appCancel || error.code == .userFallback {
            return ""
        } catch {
            return "Face ID didn’t recognize you."
        }
    }
}
