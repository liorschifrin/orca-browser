import Foundation

/// The user's preferences, saved between launches.
///
/// Shared, because tabs read `hideShorts` when they create a web view and the
/// settings page writes it.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private static let hideShortsKey = "hideShorts"
    private static let blockAdsKey = "blockAds"
    private static let blockTrackersKey = "blockTrackers"
    private static let voiceSearchProviderKey = "voiceSearchProvider"
    private static let allowsPageDialogsKey = "allowsPageDialogs"

    var voiceSearchProvider: VoiceSearchProvider {
        didSet { UserDefaults.standard.set(voiceSearchProvider.rawValue, forKey: Self.voiceSearchProviderKey) }
    }

    /// Hides YouTube Shorts in every tab. Off by default.
    var hideShorts: Bool {
        didSet { UserDefaults.standard.set(hideShorts, forKey: Self.hideShortsKey) }
    }

    /// Blocks ads in every tab. On by default.
    var blockAds: Bool {
        didSet { UserDefaults.standard.set(blockAds, forKey: Self.blockAdsKey) }
    }

    /// Blocks trackers in every tab. On by default.
    var blockTrackers: Bool {
        didSet { UserDefaults.standard.set(blockTrackers, forKey: Self.blockTrackersKey) }
    }

    /// Lets pages show alerts, confirmations and prompts. On by default; a
    /// site can also be switched off on its own (`PageDialogPermissions`).
    var allowsPageDialogs: Bool {
        didSet { UserDefaults.standard.set(allowsPageDialogs, forKey: Self.allowsPageDialogsKey) }
    }

    private init() {
        hideShorts = UserDefaults.standard.bool(forKey: Self.hideShortsKey)
        blockAds = UserDefaults.standard.object(forKey: Self.blockAdsKey) as? Bool ?? true
        blockTrackers = UserDefaults.standard.object(forKey: Self.blockTrackersKey) as? Bool ?? true
        allowsPageDialogs = UserDefaults.standard.object(forKey: Self.allowsPageDialogsKey) as? Bool ?? true
        voiceSearchProvider = VoiceSearchProvider(
            rawValue: UserDefaults.standard.string(forKey: Self.voiceSearchProviderKey) ?? ""
        ) ?? .apple
    }
}
