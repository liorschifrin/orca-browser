import Foundation

/// The user's preferences, saved between launches.
///
/// Shared, because tabs read `hideShorts` when they create a web view and the
/// settings page writes it.
@Observable
final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let defaults: UserDefaults
    private static let voiceQueryOptionsKey = "voiceQueryOptions"

    var voiceQueryOptions: VoiceQueryOptions {
        didSet {
            if let data = try? JSONEncoder().encode(voiceQueryOptions) {
                defaults.set(data, forKey: Self.voiceQueryOptionsKey)
            }
        }
    }

    private static let hideShortsKey = "hideShorts"
    private static let blockAdsKey = "blockAds"
    private static let blockTrackersKey = "blockTrackers"
    private static let blockRedditPromptKey = "blockRedditPrompt"
    private static let voiceSearchProviderKey = "voiceSearchProvider"
    private static let allowsPageDialogsKey = "allowsPageDialogs"

    var voiceSearchProvider: VoiceSearchProvider {
        didSet { defaults.set(voiceSearchProvider.rawValue, forKey: Self.voiceSearchProviderKey) }
    }

    /// Hides YouTube Shorts in every tab. Off by default.
    var hideShorts: Bool {
        didSet { defaults.set(hideShorts, forKey: Self.hideShortsKey) }
    }

    /// Blocks ads in every tab. On by default.
    var blockAds: Bool {
        didSet { defaults.set(blockAds, forKey: Self.blockAdsKey) }
    }

    /// Blocks trackers in every tab. On by default.
    var blockTrackers: Bool {
        didSet { defaults.set(blockTrackers, forKey: Self.blockTrackersKey) }
    }

    /// Removes Reddit's "get the app" pop-up. On by default.
    var blockRedditPrompt: Bool {
        didSet { defaults.set(blockRedditPrompt, forKey: Self.blockRedditPromptKey) }
    }

    /// Lets pages show alerts, confirmations and prompts. On by default; a
    /// site can also be switched off on its own (`PageDialogPermissions`).
    var allowsPageDialogs: Bool {
        didSet { defaults.set(allowsPageDialogs, forKey: Self.allowsPageDialogsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        voiceQueryOptions = defaults.data(forKey: Self.voiceQueryOptionsKey)
            .flatMap { try? JSONDecoder().decode(VoiceQueryOptions.self, from: $0) } ?? .defaults
        hideShorts = defaults.bool(forKey: Self.hideShortsKey)
        blockAds = defaults.object(forKey: Self.blockAdsKey) as? Bool ?? true
        blockTrackers = defaults.object(forKey: Self.blockTrackersKey) as? Bool ?? true
        blockRedditPrompt = defaults.object(forKey: Self.blockRedditPromptKey) as? Bool ?? true
        allowsPageDialogs = defaults.object(forKey: Self.allowsPageDialogsKey) as? Bool ?? true
        voiceSearchProvider = VoiceSearchProvider(
            rawValue: defaults.string(forKey: Self.voiceSearchProviderKey) ?? ""
        ) ?? .apple
    }
}
