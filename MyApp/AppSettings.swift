import Foundation

/// The user's preferences, saved between launches.
///
/// Shared, because tabs read `hideShorts` when they create a web view and the
/// settings page writes it.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private static let hideShortsKey = "hideShorts"
    private static let voiceSearchProviderKey = "voiceSearchProvider"

    var voiceSearchProvider: VoiceSearchProvider {
        didSet { UserDefaults.standard.set(voiceSearchProvider.rawValue, forKey: Self.voiceSearchProviderKey) }
    }

    /// Hides YouTube Shorts in every tab. Off by default.
    var hideShorts: Bool {
        didSet { UserDefaults.standard.set(hideShorts, forKey: Self.hideShortsKey) }
    }

    private init() {
        hideShorts = UserDefaults.standard.bool(forKey: Self.hideShortsKey)
        voiceSearchProvider = VoiceSearchProvider(
            rawValue: UserDefaults.standard.string(forKey: Self.voiceSearchProviderKey) ?? ""
        ) ?? .apple
    }
}
