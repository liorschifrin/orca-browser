import Foundation

/// Per-site choices made in incognito: ad and tracker blocking, and page
/// dialogs.
///
/// Normal tabs remember such choices on disk (`ContentBlocker`,
/// `PageDialogPermissions`). Incognito must not leave the sites it visited
/// behind, so its choices live only here, in memory. A choice covers every
/// incognito tab on that site, and is forgotten as soon as no incognito tab is
/// on the site any more (closed, or navigated elsewhere). A site with no
/// choice follows what the saved settings say.
final class PrivateSiteRules {
    static let shared = PrivateSiteRules()

    /// The site each incognito tab is showing.
    private var sites: [UUID: String] = [:]
    private var blocking: [ContentBlocker.Category: [String: Bool]] = [:]
    private var dialogs: [String: Bool] = [:]

    init() {}

    /// The choice made for blocking `category` on `site`, if any.
    func blocking(_ category: ContentBlocker.Category, on site: String) -> Bool? {
        blocking[category]?[site]
    }

    func setBlocking(_ enabled: Bool, _ category: ContentBlocker.Category, on site: String) {
        blocking[category, default: [:]][site] = enabled
    }

    /// The choice made for dialogs on `site`, if any.
    func allowsDialogs(on site: String) -> Bool? {
        dialogs[site]
    }

    func setAllowsDialogs(_ allowed: Bool, on site: String) {
        dialogs[site] = allowed
    }

    /// Records the site an incognito tab is now showing (nil: none), and
    /// forgets the choices for any site no tab is showing now.
    func tab(_ id: UUID, isOn site: String?) {
        sites[id] = site
        forgetUnusedSites()
    }

    /// Call when an incognito tab closes.
    func forget(tab id: UUID) {
        sites[id] = nil
        forgetUnusedSites()
    }

    private func forgetUnusedSites() {
        let shown = Set(sites.values)
        for category in blocking.keys {
            blocking[category] = blocking[category]?.filter { shown.contains($0.key) }
        }
        dialogs = dialogs.filter { shown.contains($0.key) }
    }
}
