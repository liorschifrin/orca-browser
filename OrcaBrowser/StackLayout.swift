import SwiftUI

/// The geometry of the tab deck. Everything is a fraction of the screen so it
/// works on any iPhone.
///
/// Each card has a "relative position" `d`: how far it is from the focused
/// spot, measured in cards (0 = focused, -1 = one card to the left, +1 = one
/// to the right). Position along the screen is a function of `d`, and it is
/// deliberately lopsided:
///
///  - cards to the LEFT (older) are packed tightly, so each shows only a thin
///    strip, tucked under the card on its right, slightly smaller and darker;
///  - cards to the RIGHT (newer) are spaced widely and lie on top, sliding in
///    over the focused card from the edge.
struct StackMetrics {
    let screen: CGSize
    /// Height of the status bar / notch area. The live page starts below it.
    var topInset: CGFloat = 0

    // How much of the screen a card takes up, as a fraction of its width.
    private let cardWidthFraction: CGFloat = 0.65
    /// Gap between neighbors on the left side (the thin strips).
    private var leftSpacing: CGFloat { screen.width * 0.177 }
    /// Gap between neighbors on the right side.
    private var rightSpacing: CGFloat { screen.width * 0.58 }

    var cardWidth: CGFloat { screen.width * cardWidthFraction }
    /// Same proportions as the screen, so zooming a card to full screen is a
    /// pure scale with no stretching.
    var cardHeight: CGFloat { cardWidth * screen.height / screen.width }
    var cardSize: CGSize { CGSize(width: cardWidth, height: cardHeight) }

    /// Where the focused card's top-left corner sits.
    private var originX: CGFloat { (screen.width - cardWidth) / 2 }
    private var originY: CGFloat { screen.height / 2 - cardHeight / 2 - 10 }

    /// Where the page picture starts inside a card, so a full-screen card puts
    /// the page exactly where the live page is (below the status bar).
    var contentTop: CGFloat { topInset * cardWidth / screen.width }

    /// How far a finger must travel to move the deck by one card.
    var pagePixels: CGFloat { screen.width * 0.5 }

    /// Cards on the left shrink a little with distance (never below 88%).
    func scale(forRelative d: CGFloat) -> CGFloat {
        d < 0 ? max(0.88, 1 + d * 0.025) : 1
    }

    /// Cards on the left darken with distance (up to 30% black).
    func dim(forRelative d: CGFloat) -> Double {
        d < 0 ? min(0.3, Double(-d) * 0.15) : 0
    }

    /// Where a card with relative position `d` is drawn, scale included.
    func rect(forRelative d: CGFloat) -> CGRect {
        let spacing = d < 0 ? leftSpacing : rightSpacing
        let scale = scale(forRelative: d)
        let left = originX + d * spacing
        let width = cardWidth * scale
        let height = cardHeight * scale
        return CGRect(
            x: left + (cardWidth - width) / 2,
            y: originY + (cardHeight - height) / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Open / close choreography

    /// Corner radius of a card at rest.
    static let cornerRadius: CGFloat = 20

    /// Where a card's favicon sits, measured in from the card's left edge.
    var faviconInset: CGFloat { screen.width * 0.067 }

    /// Older cards fly in from here: just above the tabs button, bottom-left.
    private var entranceCenter: CGPoint {
        CGPoint(x: screen.width * 0.13, y: screen.height * 0.91)
    }
    /// ...and start this fraction of their final size.
    private let entranceScale: CGFloat = 0.2

    /// Scale that makes a card fill the whole screen.
    private var fullScreenScale: CGFloat { screen.width / cardWidth }
    private var screenCenter: CGPoint { CGPoint(x: screen.width / 2, y: screen.height / 2) }

    /// Everything needed to draw one card at one instant.
    struct Pose {
        var center: CGPoint
        var scale: CGFloat
        /// Degrees, positive = clockwise.
        var rotation: Double
        var cornerRadius: CGFloat
        var dim: Double
        var opacity: Double
    }

    /// Blends between three situations:
    ///  - `relative`: the card's place in the deck (see the type comment);
    ///  - `entrance` 0...1: 0 = a tiny, tilted card by the tabs button,
    ///    1 = in its deck place (older cards, while opening);
    ///  - `expand` 0...1: 0 = in its deck place, 1 = filling the screen
    ///    (the current page while opening, the chosen card while leaving).
    ///
    /// Position, size and tilt all blend *linearly* with those two numbers;
    /// the springs that drive them supply the easing.
    func pose(relative: CGFloat, entrance: CGFloat, expand: CGFloat, startTilt: Double) -> Pose {
        let slot = rect(forRelative: relative)
        let slotCenter = CGPoint(x: slot.midX, y: slot.midY)
        let slotScale = scale(forRelative: relative)

        // Entrance: tiny and tilted -> deck place.
        var center = lerp(entranceCenter, slotCenter, entrance)
        var scale = lerp(slotScale * entranceScale, slotScale, entrance)
        var rotation = startTilt * Double(1 - entrance)

        // Expansion: deck place -> full screen, untilting on the way.
        center = lerp(center, screenCenter, expand)
        scale = lerp(scale, fullScreenScale, expand)
        rotation *= Double(1 - expand)

        // A card resting entirely off screen isn't drawn at all; with many
        // tabs, most of the deck lies off the left edge. The margin keeps
        // cards just out of view drawn, so paging to them doesn't stutter.
        let margin = cardWidth / 2
        let isDrawn = entrance < 1 || expand > 0
            || slot.insetBy(dx: -margin, dy: -margin).intersects(CGRect(origin: .zero, size: screen))

        return Pose(
            center: center,
            scale: scale,
            rotation: rotation,
            // Square at full screen; rounded again almost immediately.
            cornerRadius: Self.cornerRadius * min(1, 10 * (1 - expand)),
            dim: dim(forRelative: relative) * Double(1 - expand),
            // Flying-in cards appear over their first few percent of travel.
            // The floor is invisible but not zero: SwiftUI skips drawing
            // fully transparent views, which would push the cost of drawing
            // every card for the first time into the animation's first frame
            // and make its opening frames stutter.
            opacity: isDrawn ? Double(min(1, entrance * 6)) : 0
        )
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
    }
}

struct CardPreviewLayout {
    let cardSize: CGSize
    let pageSize: CGSize
    let contentTop: CGFloat
    let expansion: CGFloat

    private var progress: CGFloat { min(1, max(0, expansion)) }
    private var widthScale: CGFloat { cardSize.width / max(1, pageSize.width) }

    var scale: CGFloat {
        let fillScale = max(widthScale, cardSize.height / max(1, pageSize.height))
        return fillScale + (widthScale - fillScale) * progress
    }

    var height: CGFloat {
        cardSize.height + (pageSize.height * widthScale - cardSize.height) * progress
    }

    var topInset: CGFloat { contentTop * progress }
}

private struct CardExpansionKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

/// Lets a card's thumbnail know what corner radius the deck wants right now.
private struct CardCornerRadiusKey: EnvironmentKey {
    static let defaultValue: CGFloat = StackMetrics.cornerRadius
}

extension EnvironmentValues {
    var cardExpansion: CGFloat {
        get { self[CardExpansionKey.self] }
        set { self[CardExpansionKey.self] = newValue }
    }

    var cardCornerRadius: CGFloat {
        get { self[CardCornerRadiusKey.self] }
        set { self[CardCornerRadiusKey.self] = newValue }
    }
}

/// Places a card in the deck.
///
/// Conforming to `Animatable` is the important trick. It tells SwiftUI to
/// feed this modifier a *new interpolated value on every animation frame*,
/// so the lopsided left/right motion is recomputed each frame instead of the
/// card sliding in a straight line from start to finish.
///
/// The animated values are the card's position *relative to the focus* (not
/// the raw scroll position, so that when a tab closes and every card's index
/// shifts, the cards glide to their new places instead of jumping), plus the
/// `entrance` and `expand` blends described on `StackMetrics.pose`.
struct StackEffect: ViewModifier, Animatable {
    var relative: CGFloat
    var entrance: CGFloat
    var expand: CGFloat
    let startTilt: Double
    let metrics: StackMetrics

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(relative, AnimatablePair(entrance, expand)) }
        set {
            relative = newValue.first
            entrance = newValue.second.first
            expand = newValue.second.second
        }
    }

    func body(content: Content) -> some View {
        let pose = metrics.pose(relative: relative, entrance: entrance, expand: expand, startTilt: startTilt)

        content
            .environment(\.cardExpansion, expand)
            // The card's picture reads this to round its own corners.
            .environment(\.cardCornerRadius, pose.cornerRadius)
            .overlay {
                // Darkening for depth. Same rounded shape as the card.
                RoundedRectangle(cornerRadius: pose.cornerRadius, style: .continuous)
                    .fill(.black.opacity(pose.dim))
                    .allowsHitTesting(false)
            }
            .scaleEffect(pose.scale)
            .rotationEffect(.degrees(pose.rotation))
            // The card is laid out at the top-left corner; shift its center
            // to where it belongs.
            .offset(
                x: pose.center.x - metrics.cardWidth / 2,
                y: pose.center.y - metrics.cardHeight / 2
            )
            .opacity(pose.opacity)
    }
}
