import Foundation
import CoreGraphics
import Testing
@testable import MyApp

struct VoiceQueryOptionsTests {
    @Test func disablingEveryOptionKeepsTheLastOne() {
        var options = VoiceQueryOptions.defaults
        for destination in VoiceQueryDestination.allCases { options.setEnabled(destination, false) }
        #expect(options.active.count == 1)
        options.setEnabled(.amazon, true)
        #expect(options.active.contains(.amazon))
    }

    @Test func orderAndDisabledPositionsSurviveRoundTrip() throws {
        var options = VoiceQueryOptions.defaults
        options.setEnabled(.google, false)
        options.setEnabled(.amazon, true)
        options.move(from: IndexSet(integer: 4), to: 0)
        #expect(options.active.first == .amazon)
        let decoded = try JSONDecoder().decode(VoiceQueryOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded == options)
        options.setEnabled(.google, true)
        #expect(options.active.prefix(2) == [.amazon, .google])
    }

    @Test func unknownAndDuplicateSavedDestinationsAreRepaired() throws {
        let data = Data(#"{"order":["Unknown","YouTube","YouTube"],"enabled":["Unknown"]}"#.utf8)
        let options = try JSONDecoder().decode(VoiceQueryOptions.self, from: data)
        #expect(options.order.count == 9)
        #expect(Set(options.order).count == 9)
        #expect(options.active == [.youtube])
    }

    @MainActor @Test func configurationPersistsAndQueryUsesFirstEnabledAsDefault() throws {
        let suite = "VoiceQueryOptionsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.voiceQueryOptions.setEnabled(.google, false)
        settings.voiceQueryOptions.setEnabled(.amazon, true)
        settings.voiceQueryOptions.move(from: IndexSet(integer: 4), to: 0)
        let restored = AppSettings(defaults: defaults)
        #expect(restored.voiceQueryOptions == settings.voiceQueryOptions)
        let query = VoiceQuery(settings: restored)
        #expect(query.defaultDestination == .amazon)
        #expect(!query.destinations.contains(.google))
        query.screenSize = CGSize(width: 390, height: 800)
        query.buttonFrame = CGRect(x: 155, y: 720, width: 80, height: 44)
        query.updateSelection(at: query.center)
        #expect(query.destination == .amazon)
    }

    @Test func editedAndCustomDestinationsPersistWithStableIdentity() throws {
        var options = VoiceQueryOptions.defaults
        var google = VoiceQueryDestination.google
        google.rawValue = "My Google"
        google.color = "green"
        google.searchTemplate = "https://example.com/find?q={query}&source=voice"
        options.save(google)
        #expect(options != VoiceQueryOptions.defaults)
        let custom = VoiceQueryDestination(rawValue: "Library", symbol: "book", color: "purple",
                                           searchTemplate: "https://library.example/search/{query}")
        options.save(custom)
        options.move(from: IndexSet(integer: options.order.count - 1), to: 1)
        let decoded = try JSONDecoder().decode(VoiceQueryOptions.self, from: JSONEncoder().encode(options))
        #expect(decoded.order[0].id == VoiceQueryDestination.google.id)
        #expect(decoded.order[0].rawValue == "My Google")
        #expect(decoded.order[0].color == "green")
        #expect(decoded.order[0].searchTemplate == google.searchTemplate)
        #expect(decoded.active[1].id == custom.id)
        #expect(decoded.active[1].searchTemplate == custom.searchTemplate)
        let url = try #require(decoded.active[0].url(for: "café & + # 東京"))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "café & + # 東京")
        #expect(custom.url(for: "a/b?")?.absoluteString == "https://library.example/search/a%2Fb%3F")
        #expect(custom.url(for: "  ") == nil)
        #expect(!VoiceQueryDestination.validTemplate("https://example.com/search"))
        #expect(!VoiceQueryDestination.validTemplate("javascript:{query}"))
    }

    @Test func extraDestinationsRespectEnabledLimit() {
        var options = VoiceQueryOptions(order: VoiceQueryDestination.allCases, enabled: Set(VoiceQueryDestination.allCases))
        let extra = VoiceQueryDestination(rawValue: "Extra", searchTemplate: "https://example.com/?q={query}")
        options.save(extra)
        #expect(options.order.count == 10)
        #expect(options.active.count == 9)
        options.setEnabled(extra, true)
        #expect(!options.active.contains(extra))
        options.setEnabled(.google, false)
        options.setEnabled(extra, true)
        #expect(options.active.count == 9)
        #expect(options.active.last == extra)
    }

    @Test(arguments: 7...9)
    func ringStartsAtLeftAndRunsClockwise(count: Int) {
        let layout = VoiceQueryLayout(count: count, availableWidth: 390)
        let first = layout.offset(at: 1)
        #expect(abs(first.x + layout.radius) < 0.001)
        #expect(abs(first.y) < 0.001)
        for index in 1..<count {
            let point = layout.offset(at: index)
            var angle = atan2(point.y, point.x) - CGFloat.pi
            if angle < -0.001 { angle += 2 * .pi }
            #expect(abs(angle - CGFloat(index - 1) * 2 * .pi / CGFloat(count - 1)) < 0.001)
        }
    }

    @Test(arguments: 2...6)
    func designedLayoutsStartAtLeftAndGoClockwise(count: Int) {
        let layout = VoiceQueryLayout(count: count, availableWidth: 390)
        let outer = (1..<count).map { layout.offset(at: $0) }
        #expect(outer[0].x < layout.offset(at: 0).x)
        if count >= 5 {
            // Fan and shelves: up the left, across the top, down the right.
            let top = outer.filter { $0.y < outer[0].y - 1 }
            #expect(top.map(\.x) == top.map(\.x).sorted())
            #expect(outer.last!.x > layout.offset(at: 0).x)
        }
    }

    @Test
    func fourOptionsFormTheCompass() {
        let layout = VoiceQueryLayout(count: 4, availableWidth: 390)
        let (center, left, top, right) = (layout.offset(at: 0), layout.offset(at: 1), layout.offset(at: 2), layout.offset(at: 3))
        #expect(abs(left.y - center.y) < 0.001 && left.x < center.x)
        #expect(abs(right.y - center.y) < 0.001 && right.x > center.x)
        #expect(abs(left.x + right.x - 2 * center.x) < 0.001)
        #expect(abs(top.x - center.x) < 0.001 && top.y < center.y)
    }

    @Test(arguments: 1...9)
    func everyLayoutFitsWithoutOverlappingTargets(count: Int) {
        for width: CGFloat in [248, 320, 390, 430] {
            let layout = VoiceQueryLayout(count: count, availableWidth: width)
            let points = (0..<count).map { layout.offset(at: $0) }
            for index in 0..<count {
                let size = index == 0 ? layout.centerSize : layout.outerSize
                #expect(abs(points[index].x) + size / 2 <= width / 2)
                for other in 0..<index {
                    let otherSize = other == 0 ? layout.centerSize : layout.outerSize
                    let dx = abs(points[index].x - points[other].x)
                    let dy = abs(points[index].y - points[other].y)
                    if layout.isCircular {
                        #expect(hypot(dx, dy) > (size + otherSize) / 2 + 8)
                    } else {
                        #expect(dx >= (size + otherSize) / 2 + 4 || dy >= (size + otherSize) / 2 + 4)
                    }
                }
            }
        }
    }

    @MainActor @Test(arguments: 1...9)
    func everyEnabledTargetCanBeSelected(count: Int) throws {
        let suite = "VoiceQuerySelectionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.voiceQueryOptions = VoiceQueryOptions(
            order: VoiceQueryDestination.allCases,
            enabled: Set(VoiceQueryDestination.allCases.prefix(count))
        )
        let query = VoiceQuery(settings: settings)
        query.screenSize = CGSize(width: 320, height: 800)
        query.buttonFrame = CGRect(x: 120, y: 720, width: 80, height: 44)
        for destination in query.destinations {
            query.updateSelection(at: query.targetPoint(destination))
            #expect(query.destination == destination)
        }
    }

    @Test(arguments: [7, 8])
    func denseRingsHaveEqualVisibleGaps(count: Int) {
        let layout = VoiceQueryLayout(count: count, availableWidth: 390)
        let first = layout.offset(at: 1)
        let second = layout.offset(at: 2)
        let outerGap = hypot(first.x - second.x, first.y - second.y) - layout.outerSize
        let centerGap = layout.radius - (layout.centerSize + layout.outerSize) / 2
        #expect(abs(outerGap - centerGap) < 0.01)
    }
}
