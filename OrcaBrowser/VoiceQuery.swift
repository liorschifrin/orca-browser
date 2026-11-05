import SwiftUI

/// Destinations are explicit: a spoken domain is still a search query.
enum VoiceQueryBuiltin: String, CaseIterable, Identifiable, Codable {
    case google = "Google"
    case aiMode = "AI Mode"
    case youtube = "YouTube"
    case chatGPT = "ChatGPT"
    case amazon = "Amazon"
    case maps = "Maps"
    case reddit = "Reddit"
    case wikipedia = "Wikipedia"
    case bing = "Bing"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .google: "magnifyingglass"
        case .aiMode: "sparkles"
        case .youtube: "play.rectangle"
        case .chatGPT: "bubble.left.and.bubble.right"
        case .amazon: "cart"
        case .maps: "map"
        case .reddit: "text.bubble"
        case .wikipedia: "book"
        case .bing: "magnifyingglass.circle"
        }
    }
    var selectionColor: Color {
        switch self {
        case .google: .blue
        case .aiMode: .purple
        case .youtube: .red
        case .chatGPT: .teal
        case .amazon: .orange
        case .maps: .green
        case .reddit: .orange
        case .wikipedia: .gray
        case .bing: .cyan
        }
    }
    func url(for query: String) -> URL? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch self {
        case .chatGPT:
            return ChatGPTLink.url(for: query)
        default:
            let address: String
            var parameters: [URLQueryItem]
            switch self {
            case .google:
                address = "https://www.google.com/search"
                parameters = [URLQueryItem(name: "q", value: query)]
            case .aiMode:
                address = "https://www.google.com/search"
                parameters = [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "udm", value: "50"),
                ]
            case .youtube:
                address = "https://www.youtube.com/results"
                parameters = [URLQueryItem(name: "search_query", value: query)]
            case .amazon:
                address = "https://www.amazon.com/s"
                parameters = [URLQueryItem(name: "k", value: query)]
            case .maps:
                address = "https://www.google.com/maps/search/"
                parameters = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: query)]
            case .reddit:
                address = "https://www.reddit.com/search/"
                parameters = [URLQueryItem(name: "q", value: query)]
            case .wikipedia:
                address = "https://en.wikipedia.org/w/index.php"
                parameters = [URLQueryItem(name: "search", value: query)]
            case .bing:
                address = "https://www.bing.com/search"
                parameters = [URLQueryItem(name: "q", value: query)]
            case .chatGPT:
                return nil
            }
            var components = URLComponents(string: address)
            components?.queryItems = parameters
            return components?.url
        }
    }
}

/// Stable identity survives edits to a destination's presentation or URL.
struct VoiceQueryDestination: Identifiable, Codable, Hashable {
    let id: String
    var rawValue: String
    var symbol: String
    var color: String
    /// nil preserves the built-in action, including ChatGPT's app handoff.
    var searchTemplate: String?
    /// Set when the destination comes from a search site; then the site's icon
    /// and colour settings decide how it is drawn.
    var appearance: Appearance?

    struct Appearance: Equatable {
        var icon: SiteIconChoice
        var color: SiteColor
        var siteID: String
        var host: String
    }

    private enum CodingKeys: String, CodingKey { case id, rawValue, symbol, color, searchTemplate }

    static let allCases = VoiceQueryBuiltin.allCases.map { builtin in
        VoiceQueryDestination(id: builtin.rawValue, rawValue: builtin.rawValue,
                              symbol: builtin.symbol, color: defaultColor(builtin))
    }
    static let google = allCases[0]
    static let aiMode = allCases[1]
    static let youtube = allCases[2]
    static let chatGPT = allCases[3]
    static let amazon = allCases[4]
    static let maps = allCases[5]
    static let reddit = allCases[6]
    static let wikipedia = allCases[7]
    static let bing = allCases[8]
    static let colors = ["blue", "purple", "red", "teal", "orange", "green", "gray", "cyan"]
    static let symbols = ["magnifyingglass", "sparkles", "play.rectangle", "bubble.left.and.bubble.right", "cart", "map", "text.bubble", "book", "magnifyingglass.circle", "globe", "star", "music.note"]

    init(id: String = UUID().uuidString, rawValue: String, symbol: String = "globe",
         color: String = "blue", searchTemplate: String? = nil, appearance: Appearance? = nil) {
        self.id = id
        self.appearance = appearance
        self.rawValue = rawValue
        self.symbol = symbol
        self.color = color
        self.searchTemplate = searchTemplate
    }

    init?(rawValue: String) {
        guard let value = Self.allCases.first(where: { $0.id == rawValue }) else { return nil }
        self = value
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var selectionColor: Color {
        if let appearance {
            return SiteAppearance.color(siteID: appearance.siteID, host: appearance.host, setting: appearance.color)
        }
        return switch color {
        case "purple": .purple
        case "red": .red
        case "teal": .teal
        case "orange": .orange
        case "green": .green
        case "gray": .gray
        case "cyan": .cyan
        default: .blue
        }
    }

    var editableTemplate: String {
        if let searchTemplate { return searchTemplate }
        return VoiceQueryBuiltin(rawValue: id)?.url(for: "{query}")?.absoluteString
            .replacingOccurrences(of: "%7Bquery%7D", with: "{query}") ?? ""
    }

    static func validTemplate(_ template: String) -> Bool {
        guard template.contains("{query}"),
              let url = URL(string: template.replacingOccurrences(of: "{query}", with: "test")),
              let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http" || scheme == "com.openai.chat") && url.host?.isEmpty == false
    }

    func url(for query: String) -> URL? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let searchTemplate else { return VoiceQueryBuiltin(rawValue: id)?.url(for: query) }
        guard Self.validTemplate(searchTemplate) else { return nil }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: safe) else { return nil }
        return URL(string: searchTemplate.replacingOccurrences(of: "{query}", with: encoded))
    }

    private static func defaultColor(_ builtin: VoiceQueryBuiltin) -> String {
        switch builtin {
        case .google: "blue"
        case .aiMode: "purple"
        case .youtube: "red"
        case .chatGPT: "teal"
        case .amazon, .reddit: "orange"
        case .maps: "green"
        case .wikipedia: "gray"
        case .bing: "cyan"
        }
    }
}

/// Shared by the toolbar gesture and the screen overlay so the overlay can
/// update without creating a second voice-search session.
@MainActor @Observable
final class VoiceQuery {
    private static let activationDistance: CGFloat = 16

    let speech = VoiceSearch()
    private let settings: AppSettings

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? .shared
    }

    var destinations: [VoiceQueryDestination] { settings.voiceQueryOptions.active }
    var defaultDestination: VoiceQueryDestination { destinations[0] }
    var layout: VoiceQueryLayout { VoiceQueryLayout(count: destinations.count, availableWidth: screenSize.width) }
    var isPresented = false
    var destination = VoiceQueryDestination.google
    var isCancelling = false
    var buttonFrame = CGRect.zero
    var screenSize = CGSize.zero
    private var origin = CGPoint.zero
    private var tracking = false
    private var activated = false
    private var ignored = false
    private var awaitingFirstExit = true
    private let selectionFeedback = UISelectionFeedbackGenerator()

    var center: CGPoint {
        CGPoint(x: screenSize.width / 2, y: min(screenSize.height * 0.55, buttonFrame.midY - 150))
    }
    var targetTopExtent: CGFloat { layout.topExtent }

    func touchBegan(_ point: CGPoint) {
        guard !speech.isBusy else { return }
        origin = point
        tracking = true
        activated = false
        ignored = false
    }

    func touchMoved(_ point: CGPoint) {
        guard tracking, !ignored else { return }
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        if !activated {
            if dy < -Self.activationDistance, -dy > abs(dx) {
                activated = true
                begin()
            } else if hypot(dx, dy) > 30 {
                ignored = true
            }
        }
        if activated { updateSelection(at: point) }
    }

    func touchEnded(_ point: CGPoint, onTap: () -> Void, onSearch: @escaping (URL) -> Void) {
        guard tracking else { return }
        tracking = false
        if activated {
            updateSelection(at: point)
            isCancelling ? cancel() : finish(onSearch: onSearch)
        } else if !ignored, hypot(point.x - origin.x, point.y - origin.y) < 20 {
            onTap()
        }
    }

    func begin() {
        guard !speech.isBusy else { return }
        destination = defaultDestination
        isCancelling = false
        awaitingFirstExit = true
        selectionFeedback.prepare()
        isPresented = true
        speech.begin(provider: settings.voiceSearchProvider)
        if !speech.isBusy { isPresented = false }
    }

    func updateSelection(at point: CGPoint) {
        // Returning near the launch button cancels. Only enabled targets
        // participate in selection; the first enabled option owns the center.
        let previousDestination = destination
        let wasCancelling = isCancelling
        defer {
            if awaitingFirstExit {
                // Leaving the cancel zone at launch stays silent: the mic's
                // own haptic is about to fire and the two would double up.
                if !isCancelling { awaitingFirstExit = false }
            } else if destination != previousDestination || isCancelling != wasCancelling {
                selectionFeedback.selectionChanged()
                selectionFeedback.prepare()
            }
        }
        isCancelling = point.y > buttonFrame.minY - 48
        if !isCancelling {
            let candidates = destinations.map { option -> (VoiceQueryDestination, CGFloat) in
                let target = targetPoint(option)
                return (option, hypot(point.x - target.x, point.y - target.y))
            }
            // Pick the closest center, then retain the current selection in
            // the small boundary band. Disabled options never participate.
            if let nearest = candidates.min(by: { $0.1 < $1.1 }) {
                let currentDistance = candidates.first(where: { $0.0 == destination })?.1 ?? .infinity
                let hitRadius = max(outerTargetSize / 2 + 12, nearest.0 == defaultDestination ? layout.centerSize / 2 : 0)
                if nearest.0 == defaultDestination || nearest.1 <= hitRadius {
                    if nearest.0 == destination || nearest.1 + 8 < currentDistance {
                        destination = nearest.0
                    }
                }
            }
        }
    }

    var outerTargetSize: CGFloat { layout.outerSize }

    func targetSize(_ destination: VoiceQueryDestination) -> CGFloat {
        destination == defaultDestination ? layout.centerSize : layout.outerSize
    }

    func targetPoint(_ destination: VoiceQueryDestination) -> CGPoint {
        guard let index = destinations.firstIndex(of: destination) else { return center }
        let offset = layout.offset(at: index)
        return CGPoint(x: center.x + offset.x, y: center.y + offset.y)
    }

    func finish(onSearch: @escaping (URL) -> Void) {
        let selected = destination
        speech.finish { transcript in
            guard let url = selected.url(for: transcript) else { return }
            onSearch(url)
        }
        if !speech.isBusy { isPresented = false }
    }

    func cancel() {
        tracking = false
        activated = false
        speech.cancel()
        isPresented = false
    }
}

struct VoiceNewTabButton: View {
    let width: CGFloat
    let query: VoiceQuery
    let onTap: () -> Void
    let onSearch: (URL) -> Void
    @GestureState private var isTrackingTouch = false

    var body: some View {
        Image(systemName: query.isPresented ? "mic.fill" : "plus")
            .font(.title2.weight(.semibold))
            .foregroundStyle(query.isPresented ? Color.accentColor : Color.primary)
            .frame(width: width, height: 44)
            .background(.thinMaterial, in: .capsule)
            .contentShape(.capsule)
            .highPriorityGesture(voiceGesture)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("voiceQueryScreen")) } action: {
                query.buttonFrame = $0
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("New Tab")
            .accessibilityHint("Swipe up and hold to speak, then release to search.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
            .accessibilityAction(named: "Voice search") { query.begin() }
    }

    private var voiceGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("voiceQueryScreen"))
            .updating($isTrackingTouch) { value, state, _ in
                if !state {
                    query.touchBegan(value.startLocation)
                    state = true
                }
                query.touchMoved(value.location)
            }
            .onEnded { value in
                query.touchEnded(value.location, onTap: {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
                        onTap()
                    }, onSearch: onSearch)
            }
    }
}

struct VoiceQueryOverlay: View {
    let query: VoiceQuery
    let onSearch: (URL) -> Void

    private var canSubmit: Bool { query.speech.state == .recording }

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 12) {
                if query.speech.state != .recording { ProgressView() }
                Text(status).font(.headline)
                if !query.speech.transcript.isEmpty {
                    Text(query.speech.transcript)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .accessibilityLabel("Transcript preview: \(query.speech.transcript)")
                }
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .position(x: query.center.x, y: max(80, query.center.y - query.targetTopExtent - 76))

            ForEach(query.destinations) { destination in
                let selected = destination == query.destination && !query.isCancelling
                Button {
                    query.destination = destination
                    query.finish(onSearch: onSearch)
                } label: {
                    VStack(spacing: 8) {
                        VoiceDestinationIcon(destination: destination, tint: selected ? destination.selectionColor : .secondary)
                            .font(query.destinations.count >= 7 ? .title3 : .title2)
                        Text(destination.rawValue).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(.primary)
                    .frame(width: query.targetSize(destination), height: query.targetSize(destination))
                    .background(selected ? destination.selectionColor.opacity(0.22) : Color.secondary.opacity(0.12), in: .rect(cornerRadius: query.layout.isCircular ? query.targetSize(destination) / 2 : 24))
                    .overlay {
                        RoundedRectangle(cornerRadius: query.layout.isCircular ? query.targetSize(destination) / 2 : 24)
                            .stroke(selected ? destination.selectionColor : .clear, lineWidth: 3)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .accessibilityLabel(destination == .chatGPT ? "Open ChatGPT" : "Search \(destination.rawValue)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .position(query.targetPoint(destination))
            }

            Button(role: .cancel, action: query.cancel) {
                Label(query.isCancelling ? "Release to cancel" : "Slide down to cancel", systemImage: "xmark")
                    .font(.subheadline.weight(.medium))
                    .padding(16)
                    .background(query.isCancelling ? Color.red.opacity(0.18) : Color.secondary.opacity(0.12), in: .capsule)
            }
            .buttonStyle(.plain)
            .position(x: query.center.x, y: query.buttonFrame.midY - 18)
        }
        .accessibilityAddTraits(.isModal)
    }

    private var status: String {
        switch query.speech.state {
        case .idle: "Voice search"
        case .preparing: "Preparing microphone…"
        case .downloading: "Downloading speech model…"
        case .transcribing: "Finishing transcription…"
        case .recording:
            query.isCancelling ? "Release to cancel" : query.destination == .chatGPT ? "Release to open ChatGPT" : "Release to search \(query.destination.rawValue)"
        }
    }
}

/// The destination's icon: a symbol, or the site's own icon.
struct VoiceDestinationIcon: View {
    let destination: VoiceQueryDestination
    let tint: Color

    var body: some View {
        if let appearance = destination.appearance, appearance.icon == .site {
            SiteIconView(icon: .site, siteID: appearance.siteID, host: appearance.host, tint: tint)
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: destination.symbol).foregroundStyle(tint)
        }
    }
}
