import Foundation

/// The user's preferences, saved between launches.
///
/// Shared, because tabs read `hideShorts` and `opensShortsAsVideos` when they create a web view and the
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
    private static let opensShortsAsVideosKey = "opensShortsAsVideos"
    private static let showsPlaybackBarKey = "showsPlaybackBar"
    private static let hidesOpenAppKey = "hidesOpenApp"
    private static let showsHeaderToolsKey = "showsHeaderTools"
    private static let blockAdsKey = "blockAds"
    private static let blockTrackersKey = "blockTrackers"
    private static let blockCookieBannersKey = "blockCookieBanners"
    private static let googleInEnglishKey = "googleInEnglish"
    private static let rejectConsentKey = "rejectConsent"
    private static let blockRedditPromptKey = "blockRedditPrompt"
    private static let voiceSearchProviderKey = "voiceSearchProvider"
    private static let allowsPageDialogsKey = "allowsPageDialogs"
    private static let showDebugStatsKey = "showDebugStats"
    private static let autoArchiveTabsKey = "autoArchiveTabs"
    private static let autoArchiveDaysKey = "autoArchiveDays"
    private static let savesClipboardHistoryKey = "savesClipboardHistory"

    /// Remembers everything copied in the app and whatever is on the
    /// clipboard when it opens. On by default.
    var savesClipboardHistory: Bool {
        didSet { defaults.set(savesClipboardHistory, forKey: Self.savesClipboardHistoryKey) }
    }

    var autoArchiveTabs: Bool {
        didSet { defaults.set(autoArchiveTabs, forKey: Self.autoArchiveTabsKey) }
    }

    var autoArchiveDays: Int {
        didSet { defaults.set(autoArchiveDays, forKey: Self.autoArchiveDaysKey) }
    }

    var voiceSearchProvider: VoiceSearchProvider {
        didSet { defaults.set(voiceSearchProvider.rawValue, forKey: Self.voiceSearchProviderKey) }
    }

    /// Shows the FPS and memory indicator in the bottom bar. On by default.
    var showDebugStats: Bool {
        didSet { defaults.set(showDebugStats, forKey: Self.showDebugStatsKey) }
    }

    /// Hides YouTube Shorts in every tab. Off by default.
    var hideShorts: Bool {
        didSet { defaults.set(hideShorts, forKey: Self.hideShortsKey) }
    }

    /// Opens Shorts links as regular videos. Off by default.
    var opensShortsAsVideos: Bool {
        didSet { defaults.set(opensShortsAsVideos, forKey: Self.opensShortsAsVideosKey) }
    }

    /// Shows the playback controls above the bottom bar on YouTube watch
    /// pages. On by default.
    var showsPlaybackBar: Bool {
        didSet { defaults.set(showsPlaybackBar, forKey: Self.showsPlaybackBarKey) }
    }

    /// Hides the "Open App" button in YouTube's top bar. On by default.
    var hidesOpenApp: Bool {
        didSet { defaults.set(hidesOpenApp, forKey: Self.hidesOpenAppKey) }
    }

    /// Shows the time and the chapters button in YouTube's top bar. On by default.
    var showsHeaderTools: Bool {
        didSet { defaults.set(showsHeaderTools, forKey: Self.showsHeaderToolsKey) }
    }

    /// Blocks ads in every tab. On by default.
    var blockAds: Bool {
        didSet { defaults.set(blockAds, forKey: Self.blockAdsKey) }
    }

    /// Blocks trackers in every tab. On by default.
    var blockTrackers: Bool {
        didSet { defaults.set(blockTrackers, forKey: Self.blockTrackersKey) }
    }

    /// Hides cookie consent banners in every tab. On by default.
    var blockCookieBanners: Bool {
        didSet { defaults.set(blockCookieBanners, forKey: Self.blockCookieBannersKey) }
    }

    /// Opens Google Search and its home page in English (`GoogleLanguage`). On
    /// by default.
    var googleInEnglish: Bool {
        didSet { defaults.set(googleInEnglish, forKey: Self.googleInEnglishKey) }
    }

    /// Says no to cookie consent where a banner offers a plain reject. On by
    /// default; the site's own cookie banner switch also applies.
    var rejectConsent: Bool {
        didSet { defaults.set(rejectConsent, forKey: Self.rejectConsentKey) }
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
        savesClipboardHistory = defaults.object(forKey: Self.savesClipboardHistoryKey) as? Bool ?? true
        autoArchiveTabs = defaults.bool(forKey: Self.autoArchiveTabsKey)
        autoArchiveDays = max(1, defaults.object(forKey: Self.autoArchiveDaysKey) as? Int ?? 30)
        let hidesShorts = defaults.bool(forKey: Self.hideShortsKey)
        hideShorts = hidesShorts
        // Hiding Shorts used to open them as videos too, so keep that for
        // anyone who already had it on.
        opensShortsAsVideos = defaults.object(forKey: Self.opensShortsAsVideosKey) as? Bool ?? hidesShorts
        showsPlaybackBar = defaults.object(forKey: Self.showsPlaybackBarKey) as? Bool ?? true
        hidesOpenApp = defaults.object(forKey: Self.hidesOpenAppKey) as? Bool ?? true
        showsHeaderTools = defaults.object(forKey: Self.showsHeaderToolsKey) as? Bool ?? true
        blockAds = defaults.object(forKey: Self.blockAdsKey) as? Bool ?? true
        blockTrackers = defaults.object(forKey: Self.blockTrackersKey) as? Bool ?? true
        blockCookieBanners = defaults.object(forKey: Self.blockCookieBannersKey) as? Bool ?? true
        googleInEnglish = defaults.object(forKey: Self.googleInEnglishKey) as? Bool ?? true
        rejectConsent = defaults.object(forKey: Self.rejectConsentKey) as? Bool ?? true
        blockRedditPrompt = defaults.object(forKey: Self.blockRedditPromptKey) as? Bool ?? true
        allowsPageDialogs = defaults.object(forKey: Self.allowsPageDialogsKey) as? Bool ?? true
        voiceSearchProvider = VoiceSearchProvider(
            rawValue: defaults.string(forKey: Self.voiceSearchProviderKey) ?? ""
        ) ?? .apple
        showDebugStats = defaults.object(forKey: Self.showDebugStatsKey) as? Bool ?? true
    }
}
