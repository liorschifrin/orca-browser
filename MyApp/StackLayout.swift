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
}

/// Places a card in the deck.
///
/// Conforming to `Animatable` is the important trick. It tells SwiftUI to
/// feed this modifier a *new interpolated value on every animation frame*,
/// so the lopsided left/right motion is recomputed each frame instead of the
/// card sliding in a straight line from start to finish.
///
/// The animated value is the card's position *relative to the focus*, not
/// the raw scroll position, so that when a tab closes and every card's index
/// shifts, the cards glide to their new places instead of jumping.
struct StackEffect: ViewModifier, Animatable {
    var relative: CGFloat
    let metrics: StackMetrics

    var animatableData: CGFloat {
        get { relative }
        set { relative = newValue }
    }

    func body(content: Content) -> some View {
        let rect = metrics.rect(forRelative: relative)

        content
            .overlay {
                // Darkening for depth. Same rounded shape as the card.
                RoundedRectangle(cornerRadius: TabCard.cornerRadius, style: .continuous)
                    .fill(.black.opacity(metrics.dim(forRelative: relative)))
                    .allowsHitTesting(false)
            }
            .scaleEffect(metrics.scale(forRelative: relative))
            // The card is laid out at the top-left corner; shift its center
            // to where it belongs.
            .offset(
                x: rect.midX - metrics.cardWidth / 2,
                y: rect.midY - metrics.cardHeight / 2
            )
    }
}
