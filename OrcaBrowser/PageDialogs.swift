import Foundation

/// An alert, confirmation or text prompt a page asked to show, waiting for
/// the user's answer. The page is paused until it gets one.
struct PageDialog: Identifiable {
    enum Kind {
        case alert
        case confirm
        case prompt(defaultText: String)
    }

    enum Response {
        case ok(text: String?)
        case cancel
    }

    let id = UUID()
    let kind: Kind
    let message: String
    /// The site that asked, as `ContentBlocker.site(for:)` names it.
    let site: String?
    /// Hands the answer back to the page. Call exactly once.
    let respond: (Response) -> Void
}

/// Which sites may show dialogs. All may, unless switched off for every
/// site in Settings (`AppSettings.allowsPageDialogs`) or for one site in its
/// site menu.
@Observable
final class PageDialogPermissions {
    static let shared = PageDialogPermissions()

    private static let blockedKey = "pageDialogs.blockedSites"
    private(set) var blockedSites = Set(UserDefaults.standard.stringArray(forKey: PageDialogPermissions.blockedKey) ?? [])

    private init() {}

    /// Whether `site` may show dialogs, ignoring the global setting.
    func allows(_ site: String) -> Bool {
        !blockedSites.contains(site)
    }

    /// Whether a page on `site` may show a dialog right now.
    func mayShow(on site: String?) -> Bool {
        guard AppSettings.shared.allowsPageDialogs else { return false }
        return site.map(allows) ?? true
    }

    func setAllowed(_ allowed: Bool, on site: String) {
        if allowed { blockedSites.remove(site) } else { blockedSites.insert(site) }
        UserDefaults.standard.set(blockedSites.sorted(), forKey: Self.blockedKey)
    }
}
