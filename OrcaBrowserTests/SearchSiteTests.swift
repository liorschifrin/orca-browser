import Foundation
import Testing
@testable import OrcaBrowser

struct SearchSiteTests {
    @Test func everyBuiltInIsValidAndUnique() {
        let sites = SearchSite.builtIns
        #expect(Set(sites.map(\.id)).count == sites.count)
        for site in sites { #expect(site.validationError(among: sites) == nil, Comment(rawValue: site.name)) }
        let shortcuts = sites.flatMap(\.shortcuts)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func voiceStartsWithTheFamiliarFour() {
        let voice = SearchSitePreferences().voiceSites.map(\.name)
        #expect(voice == ["Google", "AI Mode", "YouTube", "ChatGPT"])
        #expect(SearchSite.builtIns.allSatisfy { !$0.shortcuts.isEmpty })
    }

    @Test func voiceKeepsBetweenOneAndNineSites() {
        var preferences = SearchSitePreferences()
        for site in SearchSite.builtIns { preferences.setUse(site.id, voice: true) }
        #expect(preferences.voiceCount == 9)
        let refused = preferences.setUse("imdb", voice: true)
        #expect(refused != nil)
        #expect(preferences.site(id: "imdb")?.usesVoice == false)
        for site in preferences.voiceSites.dropFirst() { preferences.setUse(site.id, voice: false) }
        #expect(preferences.setUse(preferences.voiceSites[0].id, voice: false) != nil)
        #expect(preferences.voiceCount == 1)
    }

    @Test func reorderingVoiceSitesLeavesOthersInPlace() {
        var preferences = SearchSitePreferences()
        let before = preferences.sites.map(\.id)
        preferences.moveVoice(from: IndexSet(integer: 3), to: 0)
        #expect(preferences.voiceSites.map(\.id) == ["chatgpt", "google", "ai-mode", "youtube"])
        #expect(preferences.sites.map(\.id).suffix(8) == before.suffix(8))
    }

    @Test func shortcutsStayUniqueEvenForSitesNotUsedForTyping() {
        var preferences = SearchSitePreferences()
        preferences.setUse("youtube", typing: false)
        let clash = SearchSite(name: "Mine", template: "https://example.com/?q=%s", shortcuts: ["YT "])
        #expect(preferences.save(clash)?.contains("already used") == true)
    }

    @Test func voiceOnlySiteNeedsNoShortcutButTypingDoes() {
        var preferences = SearchSitePreferences()
        let voiceOnly = SearchSite(name: "Mine", template: "https://example.com/?q=%s", usesTyping: false, usesVoice: true)
        #expect(preferences.save(voiceOnly) == nil)
        #expect(preferences.setUse(voiceOnly.id, typing: true) != nil)
    }

    @MainActor @Test func voiceListIsProjectedFromSitesAndEditsGoBack() throws {
        let suite = "SearchSiteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceQueryOptions.active.map(\.id) == ["Google", "AI Mode", "YouTube", "ChatGPT"])
        settings.voiceQueryOptions.setEnabled(.amazon, true)
        #expect(settings.searchSites.site(id: "amazon")?.usesVoice == true)
        #expect(settings.voiceQueryOptions.active.contains(.amazon))
        let restored = AppSettings(defaults: defaults)
        #expect(restored.searchSites == settings.searchSites)
        let chatGPT = try #require(restored.voiceQueryOptions.active.first { $0 == .chatGPT })
        #expect(chatGPT.searchTemplate == nil)
        let youtube = try #require(restored.voiceQueryOptions.active.first { $0 == .youtube })
        #expect(youtube.url(for: "lofi beats")?.absoluteString == "https://www.youtube.com/results?search_query=lofi%20beats")
    }

    @MainActor @Test func oldTypingAndVoiceSettingsMergeIntoOneList() throws {
        var typing = SearchSitePreferences().sites.first { $0.id == "wikipedia" }!
        typing.shortcuts = ["wp"]
        let legacyTyping = """
        {"overrides":[{"id":"wikipedia","name":"Wikipedia","shortcuts":["wp"],"template":"\(typing.template)","isEnabled":false},
                      {"id":"mine","name":"Mine","shortcuts":["m"],"template":"https://example.com/?q=%s","isEnabled":true}],
         "removedIDs":["imdb"]}
        """
        var options = VoiceQueryOptions.defaults
        options.setEnabled(.amazon, true)
        options.setEnabled(.google, false)
        let youtube = VoiceQueryDestination(
            id: "YouTube", rawValue: "YouTube", symbol: "play.rectangle", color: "red",
            searchTemplate: "https://www.youtube.com/results?search_query={query}&hl=cs"
        )
        options.save(youtube)
        let migrated = SearchSitePreferences.migrated(
            typing: Data(legacyTyping.utf8), voice: try JSONEncoder().encode(options)
        )
        #expect(migrated.site(id: "wikipedia")?.shortcuts == ["wp"])
        #expect(migrated.site(id: "wikipedia")?.usesTyping == false)
        #expect(migrated.site(id: "mine")?.shortcuts == ["m"])
        #expect(migrated.site(id: "imdb") == nil)
        #expect(migrated.site(id: "google")?.usesVoice == false)
        #expect(migrated.site(id: "amazon")?.usesVoice == true)
        #expect(migrated.site(id: "youtube")?.template.hasSuffix("&hl=cs") == true)
        #expect(migrated.site(id: "youtube")?.shortcuts == ["yt"])
    }

    @Test(arguments: [false, true]) func migrationDoesNotReclaimRemovedShortcuts(voiceEnabled: Bool) throws {
        let typing = Data(#"{"overrides":[{"id":"mine","name":"Mine","shortcuts":["A"],"template":"https://example.com/?q=%s"}],"removedIDs":["amazon"]}"#.utf8)
        var options = VoiceQueryOptions.defaults
        options.setEnabled(.amazon, voiceEnabled)
        let migrated = SearchSitePreferences.migrated(typing: typing, voice: try JSONEncoder().encode(options))
        let amazon = try #require(migrated.site(id: "amazon"))
        #expect(!amazon.usesTyping)
        #expect(amazon.usesVoice == voiceEnabled)
        #expect(amazon.shortcuts == ["amz"])
        let mine = try #require(migrated.site(id: "mine"))
        #expect(mine.validationError(among: migrated.sites) == nil)
    }

    @Test(arguments: ["YouTube", "ChatGPT"]) func incompatibleLegacyVoiceTemplatePreservesTyping(id: String) throws {
        let destination = VoiceQueryDestination(id: id, rawValue: id, searchTemplate: "http://example.com/?q={query}")
        let options = VoiceQueryOptions(order: [destination], enabled: [destination])
        let migrated = SearchSitePreferences.migrated(typing: nil, voice: try JSONEncoder().encode(options))
        let site = try #require(migrated.site(id: SearchSite.siteID(forVoiceID: id)))
        #expect(site.provider.url(for: "hello") != nil)
        #expect(site.template == SearchSite.builtIns.first { $0.id == site.id }?.template)
        #expect(!site.usesVoice)
        let voice = try #require(migrated.voiceSites.first { $0.name == "\(id) (voice)" })
        #expect(!voice.usesTyping)
        #expect(!voice.opensChatGPTApp)
        #expect(voice.voiceDestination.searchTemplate == destination.searchTemplate)
    }

    @Test func disabledTypingTemplateIsPreservedDuringVoiceMigration() throws {
        let typing = Data(#"{"overrides":[{"id":"youtube","name":"YouTube","shortcuts":["yt"],"template":"https://www.youtube.com/results?search_query=%s&hl=cs","isEnabled":false}],"removedIDs":[]}"#.utf8)
        let destination = VoiceQueryDestination(id: "YouTube", rawValue: "YouTube", searchTemplate: "https://example.com/?q={query}")
        let options = VoiceQueryOptions(order: [destination], enabled: [destination])
        let migrated = SearchSitePreferences.migrated(typing: typing, voice: try JSONEncoder().encode(options))
        #expect(migrated.site(id: "youtube")?.template.hasSuffix("&hl=cs") == true)
        #expect(migrated.site(id: "youtube")?.usesTyping == false)
        #expect(migrated.voiceSites.first { $0.name == "YouTube (voice)" }?.template == "https://example.com/?q=%s")
    }

    @Test func removedTypingSiteKeepsSingleCustomVoiceEntry() throws {
        let typing = Data(#"{"overrides":[],"removedIDs":["chatgpt"]}"#.utf8)
        let destination = VoiceQueryDestination(id: "ChatGPT", rawValue: "ChatGPT", searchTemplate: "http://example.com/?q={query}")
        let options = VoiceQueryOptions(order: [destination], enabled: [destination])
        let migrated = SearchSitePreferences.migrated(typing: typing, voice: try JSONEncoder().encode(options))
        let site = try #require(migrated.site(id: "chatgpt"))
        #expect(!site.usesTyping)
        #expect(!site.opensChatGPTApp)
        #expect(site.voiceDestination.searchTemplate == destination.searchTemplate)
        #expect(migrated.sites.filter { $0.name.hasPrefix("ChatGPT") }.count == 1)
    }

    @Test func templatesRoundTripBetweenTypingAndVoiceSyntax() throws {
        let site = try #require(SearchSite.builtIns.first { $0.id == "amazon" })
        #expect(site.voiceDestination.searchTemplate == "https://www.amazon.com/s?k={query}")
        #expect(site.voiceDestination.url(for: "a&b")?.absoluteString == "https://www.amazon.com/s?k=a%26b")
        #expect(site.provider.url(for: "a&b")?.absoluteString == "https://www.amazon.com/s?k=a%26b")
    }

    @Test func iconLinksPreferTouchIconsAndSkipSVG() throws {
        let html = """
        <link rel="icon" href="/favicon.svg"><link rel="shortcut icon" href='/fav.png'>
        <link rel="apple-touch-icon" sizes="180x180" href="/touch.png"><link rel="stylesheet" href="/a.css">
        """
        let links = SiteIconStore.iconLinks(in: html, base: try #require(URL(string: "https://example.com/")))
        #expect(links.map(\.absoluteString) == ["https://example.com/touch.png", "https://example.com/fav.png"])
    }
}
