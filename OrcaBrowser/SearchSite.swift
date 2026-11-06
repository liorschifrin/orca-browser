import SwiftUI

/// What a site looks like in one place (the typing chip or the voice layout).
enum SiteIconChoice: Codable, Equatable, Hashable {
    /// The site's fetched icon, falling back to a bundled logo, then a globe.
    case site
    case symbol(String)

    var symbolName: String? {
        if case .symbol(let name) = self { name } else { nil }
    }
}

enum SiteColor: Codable, Equatable, Hashable {
    /// The site's own colour: a known brand colour, else its icon's main colour.
    case site
    /// "#RRGGBB"
    case custom(String)

    /// How the voice layout's destinations carry it.
    var name: String {
        switch self {
        case .site: "site"
        case .custom(let hex): hex
        }
    }
}

/// One place a search can go: typed after a shortcut, chosen by voice, or both.
/// The template has a single `%s` where the query goes.
struct SearchSite: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var template: String
    var shortcuts: [String] = []
    var usesTyping = true
    var usesVoice = false
    var typingIcon = SiteIconChoice.site
    var voiceIcon = SiteIconChoice.site
    var typingColor = SiteColor.site
    var voiceColor = SiteColor.site
    /// Voice hands the query to the ChatGPT app instead of opening the template.
    var opensChatGPTApp = false

    // Add built-ins here with a stable ID; saved edits take precedence. The
    // first nine with `usesVoice` are the voice layout, in this order.
    static let builtIns: [SearchSite] = [
        .init(id: "google", name: "Google", template: "https://www.google.com/search?q=%s", shortcuts: ["g"], usesVoice: true, voiceIcon: .symbol("magnifyingglass")),
        .init(id: "ai-mode", name: "AI Mode", template: "https://www.google.com/search?udm=50&q=%s", shortcuts: ["aimode"], usesVoice: true, voiceIcon: .symbol("sparkles")),
        .init(id: "youtube", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s", shortcuts: ["yt"], usesVoice: true, voiceIcon: .symbol("play.rectangle")),
        .init(id: "chatgpt", name: "ChatGPT", template: "https://chatgpt.com/?prompt=%s", shortcuts: ["gpt"], usesVoice: true, voiceIcon: .symbol("bubble.left.and.bubble.right"), opensChatGPTApp: true),
        .init(id: "amazon", name: "Amazon", template: "https://www.amazon.com/s?k=%s", shortcuts: ["a", "amz"], voiceIcon: .symbol("cart")),
        .init(id: "maps", name: "Maps", template: "https://www.google.com/maps/search/?api=1&query=%s", shortcuts: ["map"], voiceIcon: .symbol("map")),
        .init(id: "reddit", name: "Reddit", template: "https://www.reddit.com/search/?q=%s", shortcuts: ["r", "reddit"], voiceIcon: .symbol("text.bubble")),
        .init(id: "wikipedia", name: "Wikipedia", template: "https://en.wikipedia.org/wiki/Special:Search?search=%s", shortcuts: ["w", "wiki"], voiceIcon: .symbol("book")),
        .init(id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%s", shortcuts: ["bing"], voiceIcon: .symbol("magnifyingglass.circle")),
        .init(id: "google-images", name: "Google Images", template: "https://www.google.com/search?udm=2&q=%s", shortcuts: ["gi", "img"]),
        .init(id: "google-translate", name: "Google Translate", template: "https://translate.google.com/?sl=auto&tl=en&text=%s&op=translate", shortcuts: ["gt", "tr"]),
        .init(id: "imdb", name: "IMDb", template: "https://www.imdb.com/find/?q=%s", shortcuts: ["imdb"]),
    ]

    /// Voice used these names before sites were shared with typing.
    static let voiceIDs = [
        "google": "Google", "ai-mode": "AI Mode", "youtube": "YouTube", "chatgpt": "ChatGPT",
        "amazon": "Amazon", "maps": "Maps", "reddit": "Reddit", "wikipedia": "Wikipedia", "bing": "Bing",
    ]

    var voiceID: String { Self.voiceIDs[id] ?? id }

    static func siteID(forVoiceID voiceID: String) -> String {
        voiceIDs.first { $0.value == voiceID }?.key ?? voiceID
    }

    var host: String {
        URLComponents(string: template.replacingOccurrences(of: "%s", with: "query"))?.host ?? ""
    }

    var voiceDestination: VoiceQueryDestination {
        VoiceQueryDestination(
            id: voiceID, rawValue: name, symbol: voiceIcon.symbolName ?? "globe", color: voiceColor.name,
            searchTemplate: opensChatGPTApp ? nil : template.replacingOccurrences(of: "%s", with: "{query}"),
            appearance: .init(icon: voiceIcon, color: voiceColor, siteID: id, host: host)
        )
    }

    var provider: SearchProvider {
        SearchProvider(id: id, name: name, shortcuts: shortcuts, template: template, isEnabled: usesTyping,
                       icon: typingIcon, color: typingColor)
    }

    func normalized() -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.shortcuts = shortcuts.map(SearchProvider.normalize).filter { !$0.isEmpty }
        copy.template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    func validationError(among sites: [Self]) -> String? {
        let candidate = normalized()
        if candidate.shortcuts.isEmpty {
            guard !candidate.name.isEmpty, candidate.name.count <= 80 else {
                return "Enter a name of 1–80 characters."
            }
            if candidate.usesTyping { return "Add at least one shortcut to use this site when typing." }
            return SearchProvider.templateError(candidate.template)
        }
        let others = sites.filter { $0.id != id }.map(\.provider)
        return candidate.provider.validationError(among: others + [candidate.provider])
    }

    // Saved lists keep loading when a field is added later.
    private enum CodingKeys: String, CodingKey {
        case id, name, template, shortcuts, usesTyping, usesVoice
        case typingIcon, voiceIcon, typingColor, voiceColor, opensChatGPTApp
    }

    init(id: String = UUID().uuidString, name: String, template: String, shortcuts: [String] = [],
         usesTyping: Bool = true, usesVoice: Bool = false,
         typingIcon: SiteIconChoice = .site, voiceIcon: SiteIconChoice = .site,
         typingColor: SiteColor = .site, voiceColor: SiteColor = .site,
         opensChatGPTApp: Bool = false) {
        self.id = id
        self.name = name
        self.template = template
        self.shortcuts = shortcuts
        self.usesTyping = usesTyping
        self.usesVoice = usesVoice
        self.typingIcon = typingIcon
        self.voiceIcon = voiceIcon
        self.typingColor = typingColor
        self.voiceColor = voiceColor
        self.opensChatGPTApp = opensChatGPTApp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            template: try c.decode(String.self, forKey: .template),
            shortcuts: try c.decodeIfPresent([String].self, forKey: .shortcuts) ?? [],
            usesTyping: try c.decodeIfPresent(Bool.self, forKey: .usesTyping) ?? true,
            usesVoice: try c.decodeIfPresent(Bool.self, forKey: .usesVoice) ?? false,
            typingIcon: try c.decodeIfPresent(SiteIconChoice.self, forKey: .typingIcon) ?? .site,
            voiceIcon: try c.decodeIfPresent(SiteIconChoice.self, forKey: .voiceIcon) ?? .site,
            typingColor: try c.decodeIfPresent(SiteColor.self, forKey: .typingColor) ?? .site,
            voiceColor: try c.decodeIfPresent(SiteColor.self, forKey: .voiceColor) ?? .site,
            opensChatGPTApp: try c.decodeIfPresent(Bool.self, forKey: .opensChatGPTApp) ?? false
        )
    }
}

/// The saved list. Built-ins added in later versions appear at the end; ones
/// the user removed stay removed.
struct SearchSitePreferences: Codable, Equatable {
    static let maxVoiceSites = 9

    private(set) var sites: [SearchSite]
    private(set) var removedIDs: Set<String>
    private var knownBuiltInIDs: Set<String>

    init() {
        sites = SearchSite.builtIns
        removedIDs = []
        knownBuiltInIDs = Set(SearchSite.builtIns.map(\.id))
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sites = try c.decode([SearchSite].self, forKey: .sites)
        removedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .removedIDs) ?? []
        knownBuiltInIDs = try c.decodeIfPresent(Set<String>.self, forKey: .knownBuiltInIDs) ?? []
        reconcile()
    }

    private enum CodingKeys: String, CodingKey { case sites, removedIDs, knownBuiltInIDs }

    private mutating func reconcile() {
        for builtIn in SearchSite.builtIns where !knownBuiltInIDs.contains(builtIn.id) {
            knownBuiltInIDs.insert(builtIn.id)
            if !removedIDs.contains(builtIn.id), !sites.contains(where: { $0.id == builtIn.id }) {
                var added = builtIn
                // A new built-in never takes a voice slot the user has filled.
                if voiceCount >= Self.maxVoiceSites { added.usesVoice = false }
                sites.append(added)
            }
        }
    }

    var voiceCount: Int { sites.filter(\.usesVoice).count }
    var voiceSites: [SearchSite] { sites.filter(\.usesVoice) }

    func site(id: String) -> SearchSite? { sites.first { $0.id == id } }

    var voiceOptions: VoiceQueryOptions {
        let destinations = sites.map(\.voiceDestination)
        return VoiceQueryOptions(exactOrder: destinations, enabled: Set(sites.filter(\.usesVoice).map(\.voiceDestination)))
    }

    /// Why turning voice on or off for this site isn't allowed, if it isn't.
    func voiceChangeError(for site: SearchSite, enabling: Bool) -> String? {
        let currentlyOn = self.site(id: site.id)?.usesVoice ?? false
        if enabling, !currentlyOn, voiceCount >= Self.maxVoiceSites {
            return "Voice search shows up to \(Self.maxVoiceSites) sites. Turn another one off first."
        }
        if !enabling, currentlyOn, voiceCount <= 1 {
            return "Voice search needs at least one site."
        }
        return nil
    }

    /// Adds or replaces a site. Returns the reason it was refused, if it was.
    @discardableResult
    mutating func save(_ site: SearchSite) -> String? {
        let site = site.normalized()
        if let error = site.validationError(among: sites) { return error }
        if let error = voiceChangeError(for: site, enabling: site.usesVoice) { return error }
        if let index = sites.firstIndex(where: { $0.id == site.id }) {
            sites[index] = site
        } else {
            sites.append(site)
        }
        removedIDs.remove(site.id)
        return nil
    }

    @discardableResult
    mutating func setUse(_ id: String, typing: Bool? = nil, voice: Bool? = nil) -> String? {
        guard var site = site(id: id) else { return nil }
        if let typing {
            if typing, site.shortcuts.isEmpty { return "Add a shortcut in the site's settings to use it when typing." }
            site.usesTyping = typing
        }
        if let voice {
            if let error = voiceChangeError(for: site, enabling: voice) { return error }
            site.usesVoice = voice
        }
        if let index = sites.firstIndex(where: { $0.id == id }) { sites[index] = site }
        return nil
    }

    @discardableResult
    mutating func remove(_ id: String) -> String? {
        guard let site = site(id: id) else { return nil }
        if site.usesVoice, voiceCount <= 1 { return "Voice search needs at least one site." }
        if sites.count <= 1 { return "Keep at least one site." }
        sites.removeAll { $0.id == id }
        removedIDs.insert(id)
        return nil
    }

    /// Reorders among the voice sites only; the others keep their places.
    mutating func moveVoice(from offsets: IndexSet, to destination: Int) {
        var voice = voiceSites
        voice.move(fromOffsets: offsets, toOffset: destination)
        var next = voice.makeIterator()
        sites = sites.map { $0.usesVoice ? (next.next() ?? $0) : $0 }
    }

    /// Writes edits made through the voice layout back into the sites.
    mutating func apply(_ options: VoiceQueryOptions) {
        let enabled = options.enabled
        var reordered: [SearchSite] = []
        var seen = Set<String>()
        for destination in options.order {
            let id = SearchSite.siteID(forVoiceID: destination.id)
            var site = sites.first { $0.id == id } ?? SearchSite(id: id, name: destination.rawValue, template: "https://example.com/?q=%s", usesTyping: false)
            site.name = destination.rawValue
            site.usesVoice = enabled.contains(destination)
            if destination.symbol != site.voiceIcon.symbolName ?? "globe" {
                site.voiceIcon = .symbol(destination.symbol)
            }
            if let template = destination.searchTemplate {
                site.template = template.replacingOccurrences(of: "{query}", with: "%s")
            }
            if destination.color != site.voiceColor.name {
                site.voiceColor = destination.color == "site" ? .site
                    : .custom(SiteColors.names.contains(destination.color) ? SiteColors.hex(forName: destination.color) : destination.color)
            }
            reordered.append(site)
            seen.insert(id)
        }
        reordered += sites.filter { !seen.contains($0.id) }
        sites = reordered
    }

    // MARK: Migration

    private struct LegacyProvider: Decodable {
        var id: String
        var name: String
        var shortcuts: [String]
        var template: String
        var isEnabled: Bool?
    }

    private struct LegacyTyping: Decodable {
        var overrides: [LegacyProvider] = []
        var removedIDs: Set<String> = []
    }

    /// Builds the list from the two lists that came before it. The old data
    /// is left where it is, so an older build still finds it.
    static func migrated(typing: Data?, voice: Data?) -> Self {
        var result = Self()
        if let typing, let old = try? JSONDecoder().decode(LegacyTyping.self, from: typing) {
            for id in old.removedIDs {
                result.sites.removeAll { $0.id == id }
                result.removedIDs.insert(id)
            }
            for provider in old.overrides where !old.removedIDs.contains(provider.id) {
                if let index = result.sites.firstIndex(where: { $0.id == provider.id }) {
                    result.sites[index].name = provider.name
                    result.sites[index].shortcuts = provider.shortcuts
                    result.sites[index].template = provider.template
                    result.sites[index].usesTyping = provider.isEnabled ?? true
                } else {
                    result.sites.append(SearchSite(id: provider.id, name: provider.name, template: provider.template,
                                                   shortcuts: provider.shortcuts, usesTyping: provider.isEnabled ?? true))
                }
            }
        }
        if let voice, let options = try? JSONDecoder().decode(VoiceQueryOptions.self, from: voice) {
            result.mergeLegacyVoice(options)
        }
        return result
    }

    private mutating func mergeLegacyVoice(_ options: VoiceQueryOptions) {
        var ordered: [SearchSite] = []
        for destination in options.order {
            let id = SearchSite.siteID(forVoiceID: destination.id)
            let builtInDefault = VoiceQueryDestination(rawValue: destination.id)
            let taken = Set(sites.filter { $0.id != id }.flatMap(\.shortcuts).map(SearchProvider.normalize))
            let hasExistingSite = sites.contains { $0.id == id }
            // Deleted from typing: keep it for voice only without reclaiming shortcuts.
            var site = sites.first { $0.id == id }
                ?? SearchSite.builtIns.first { $0.id == id }.map {
                    var restored = $0
                    restored.usesTyping = false
                    restored.shortcuts.removeAll { taken.contains(SearchProvider.normalize($0)) }
                    return restored
                }
                ?? SearchSite(id: id, name: destination.rawValue, template: "https://example.com/?q=%s", usesTyping: false)
            let wasEnabled = options.enabled.contains(destination)
            site.name = destination.rawValue
            if destination.symbol != builtInDefault?.symbol || builtInDefault == nil {
                site.voiceIcon = .symbol(destination.symbol)
            }
            if destination.color != builtInDefault?.color {
                site.voiceColor = .custom(SiteColors.hex(forName: destination.color))
            }
            if let voiceTemplate = destination.searchTemplate?.replacingOccurrences(of: "{query}", with: "%s"),
               voiceTemplate != site.template || site.opensChatGPTApp {
                let typingWasEdited = SearchSite.builtIns.first { $0.id == id }.map { $0.template != site.template } ?? false
                let canShareTemplate = SearchProvider.templateError(voiceTemplate) == nil && !site.opensChatGPTApp
                if hasExistingSite && (typingWasEdited || !canShareTemplate) {
                    // Preserve typing when the voice customisation cannot serve both uses.
                    var voiceOnly = site
                    voiceOnly.id = UUID().uuidString
                    voiceOnly.name = "\(destination.rawValue) (voice)"
                    voiceOnly.template = voiceTemplate
                    voiceOnly.shortcuts = []
                    voiceOnly.usesTyping = false
                    voiceOnly.usesVoice = wasEnabled
                    voiceOnly.opensChatGPTApp = false
                    ordered.append(voiceOnly)
                    site.usesVoice = false
                    ordered.append(site)
                    continue
                }
                site.template = voiceTemplate
            }
            if destination.searchTemplate != nil { site.opensChatGPTApp = false }
            site.usesVoice = wasEnabled
            ordered.append(site)
        }
        let placed = Set(ordered.map(\.id))
        sites = ordered + sites.filter { !placed.contains($0.id) }.map { var s = $0; s.usesVoice = false; return s }
        removedIDs.subtract(placed)
    }
}

enum SiteColors {
    static let names = ["blue", "purple", "red", "teal", "orange", "green", "gray", "cyan"]

    /// Colours the sites are known by. Anything else uses its icon's main colour.
    static let brand: [String: String] = [
        "google": "#4285F4", "ai-mode": "#8957E5", "youtube": "#FF0000", "chatgpt": "#10A37F",
        "amazon": "#FF9900", "maps": "#34A853", "reddit": "#FF4500", "wikipedia": "#636466",
        "bing": "#008373", "google-images": "#4285F4", "google-translate": "#4285F4", "imdb": "#F5C518",
    ]

    static func hex(forName name: String) -> String {
        switch name {
        case "purple": "#AF52DE"
        case "red": "#FF3B30"
        case "teal": "#30B0C7"
        case "orange": "#FF9500"
        case "green": "#34C759"
        case "gray": "#8E8E93"
        case "cyan": "#32ADE6"
        default: "#007AFF"
        }
    }

    static func color(hex: String) -> Color? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static func hex(of color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// Light colours need dark text on top.
    static func isLight(_ color: Color) -> Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.299 * red + 0.587 * green + 0.114 * blue > 0.62
    }
}
