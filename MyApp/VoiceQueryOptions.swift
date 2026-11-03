import Foundation
import CoreGraphics

/// Stores stable destination identities independently of which are enabled.
/// Disabled rows keep their place so turning one back on restores its order.
struct VoiceQueryOptions: Codable, Equatable {
    private(set) var order: [VoiceQueryDestination]
    private(set) var enabled: Set<VoiceQueryDestination>

    static let defaults = VoiceQueryOptions(
        order: VoiceQueryDestination.allCases,
        enabled: [.google, .aiMode, .youtube, .chatGPT]
    )

    var active: [VoiceQueryDestination] { order.filter { enabled.contains($0) } }

    init(order: [VoiceQueryDestination], enabled: Set<VoiceQueryDestination>) {
        var seen: Set<VoiceQueryDestination> = []
        self.order = (order + VoiceQueryDestination.allCases).filter { seen.insert($0).inserted }
        let selected = self.order.filter { enabled.contains($0) }.prefix(9)
        self.enabled = selected.isEmpty ? [self.order[0]] : Set(selected)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled && lhs.order.count == rhs.order.count &&
        zip(lhs.order, rhs.order).allSatisfy { left, right in
            left.id == right.id && left.rawValue == right.rawValue &&
            left.symbol == right.symbol && left.color == right.color &&
            left.searchTemplate == right.searchTemplate
        }
    }

    mutating func setEnabled(_ destination: VoiceQueryDestination, _ isEnabled: Bool) {
        if isEnabled {
            if enabled.count < 9 { enabled.insert(destination) }
        } else if enabled.count > 1 {
            enabled.remove(destination)
        }
    }

    mutating func move(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().filter { order.indices.contains($0) }
        let values = moving.map { order[$0] }
        let remaining = order.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = min(remaining.count, max(0, destination - moving.filter { $0 < destination }.count))
        order = Array(remaining.prefix(insertion)) + values + Array(remaining.dropFirst(insertion))
    }

    mutating func save(_ destination: VoiceQueryDestination) {
        if let index = order.firstIndex(of: destination) {
            order[index] = destination
            if enabled.remove(destination) != nil { enabled.insert(destination) }
        } else {
            order.append(destination)
            if enabled.count < 9 { enabled.insert(destination) }
        }
    }

    private enum CodingKeys: String, CodingKey { case order, enabled }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedOrder: [VoiceQueryDestination]
        if let legacy = try? container.decode([String].self, forKey: .order) {
            savedOrder = legacy.compactMap(VoiceQueryDestination.init(rawValue:))
        } else {
            savedOrder = try container.decode([VoiceQueryDestination].self, forKey: .order)
        }
        let ids = try container.decode([String].self, forKey: .enabled)
        self.init(order: savedOrder, enabled: Set(savedOrder.filter { ids.contains($0.id) }.prefix(9)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order, forKey: .order)
        try container.encode(active.map(\.id), forKey: .enabled)
    }

}

/// Shared geometry for drawing and hit testing. One to six options follow the
/// designed arrangements (row, compass, upper fan, two shelves); seven to nine
/// use circular targets on a ring with equal gaps around the center. The first
/// option is always the default; the rest start at the left and run clockwise.
struct VoiceQueryLayout {
    let count: Int
    let availableWidth: CGFloat

    private var scale: CGFloat { min(1, max(1, availableWidth) / 320) }
    var radius: CGFloat { min(112, max(110, (availableWidth / scale - 100) / 2)) * scale }
    var isCircular: Bool { count >= 7 }
    var outerSize: CGFloat { (isCircular ? 68 : 80) * scale }
    var centerSize: CGFloat {
        if count == 7 { return outerSize }
        if count == 8 {
            // Match center-to-neighbor gaps to the gaps around a heptagon.
            return 2 * (radius - 2 * radius * sin(.pi / 7) + outerSize / 2)
        }
        return 92 * scale
    }

    /// Distance from the layout center up to the top edge of the highest target.
    var topExtent: CGFloat {
        (0..<max(count, 1)).map { index in
            -offset(at: index).y + (index == 0 ? centerSize : outerSize) / 2
        }.max() ?? 0
    }

    /// Designed positions as percentages of the target field (326 x 207),
    /// listed default first, then left-first clockwise.
    private static let designed: [Int: [(x: CGFloat, y: CGFloat)]] = [
        1: [(50, 50)],
        2: [(50, 52), (17, 52)],
        3: [(50, 52), (17, 52), (83, 52)],
        4: [(50, 65), (17, 65), (50, 17), (83, 65)],
        5: [(50, 76), (15, 55), (33, 14), (67, 14), (85, 55)],
        6: [(50, 74), (17, 74), (17, 18), (50, 18), (83, 18), (83, 74)],
    ]

    func offset(at index: Int) -> CGPoint {
        guard index >= 0, index < count else { return .zero }
        if let points = Self.designed[count] {
            let fieldWidth = min(326, availableWidth / scale - 24) * scale
            let fieldHeight: CGFloat = 207
            return CGPoint(x: (points[index].x - 50) / 100 * fieldWidth,
                           y: (points[index].y - 50) / 100 * fieldHeight)
        }
        guard index > 0 else { return .zero }
        let r = radius
        // Screen coordinates increase downward: increasing the angle from
        // the leftmost point walks clockwise through the upper half first.
        let angle = CGFloat.pi + CGFloat(index - 1) * 2 * .pi / CGFloat(count - 1)
        return CGPoint(x: cos(angle) * r, y: sin(angle) * r)
    }
}
