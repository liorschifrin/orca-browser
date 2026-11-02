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

    private static let searchProvidersKey = "searchProviders.v1"

    var searchProviderPreferences: SearchProviderPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(searchProviderPreferences) {
                UserDefaults.standard.set(data, forKey: Self.searchProvidersKey)
            }
        }
    }

    var searchProviders: [SearchProvider] { searchProviderPreferences.providers }

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

    private init() {
        searchProviderPreferences = UserDefaults.standard.data(forKey: Self.searchProvidersKey)
            .flatMap { try? JSONDecoder().decode(SearchProviderPreferences.self, from: $0) }
            ?? SearchProviderPreferences()
        hideShorts = UserDefaults.standard.bool(forKey: Self.hideShortsKey)
        blockAds = UserDefaults.standard.object(forKey: Self.blockAdsKey) as? Bool ?? true
        blockTrackers = UserDefaults.standard.object(forKey: Self.blockTrackersKey) as? Bool ?? true
        voiceSearchProvider = VoiceSearchProvider(
            rawValue: UserDefaults.standard.string(forKey: Self.voiceSearchProviderKey) ?? ""
        ) ?? .apple
    }
}
