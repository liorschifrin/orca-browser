import SwiftUI

/// One tab in the switcher: a picture of the page, with the site's icon above
/// it (and, for the focused card only, the page title beside the icon).
/// Swipe it up to close it, like closing an app in the iOS app switcher.
///
/// The card knows nothing about where it sits in the deck; `StackEffect`
/// positions, scales and tilts it from outside. The card's own box is exactly
/// the thumbnail, and the header floats above that box.
struct TabCard: View {
    let tab: Tab
    let size: CGSize
    /// How far the favicon's center sits in from the card's left edge.
    let faviconInset: CGFloat
    /// How far down the card the page picture starts (the status bar's share).
    let contentTop: CGFloat
    /// 1 when this card is the focused one, fading to 0 as it moves away.
    /// Controls the title and close button, which only the focused card shows.
    let focus: Double
    let onSelect: () -> Void
    let onClose: () -> Void

    /// How far the finger has dragged the card upward (zero or negative).
    @State private var dragOffset: CGFloat = 0
    /// Whether the current drag is vertical. Decided once, at the start, so
    /// a drag that begins sideways (browsing) never turns into a close.
    @State private var isVerticalDrag: Bool?

    /// Chosen by the deck, which makes the corners square while a card fills
    /// the screen.
    @Environment(\.cardCornerRadius) private var cornerRadius

    /// Gap between the card's top edge and the center of the favicon.
    private let headerGap: CGFloat = 18
    private let faviconSize: CGFloat = 18
    /// Past this much upward travel, letting go closes the tab.
    private let closeDistance: CGFloat = 120

    var body: some View {
        thumbnail
            .overlay(alignment: .topTrailing) { closeButton }
            .overlay(alignment: .top) {
                header
                    // Sit just above the card instead of inside it.
                    .offset(y: -(headerGap + faviconSize / 2))
            }
            .offset(y: dragOffset)
            // Fade and shrink a little as it rises, so it's clear it's going away.
            .opacity(1 - min(abs(dragOffset) / 400, 0.7))
            .scaleEffect(1 - min(abs(dragOffset) / 1500, 0.15))
            .contentShape(.rect)
            .onTapGesture(perform: onSelect)
            // simultaneousGesture lets the deck keep paging sideways while
            // we also watch for upward drags on the card.
            .simultaneousGesture(swipeToClose)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tab.title?.isEmpty == false ? tab.title! : tab.displayName)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Close tab", onClose)
    }

    // MARK: - Pieces

    private var thumbnail: some View {
        // With a picture, the card is the screen in miniature: the picture is
        // exactly as wide as the card and sits at its top, which is where the
        // live page sits on screen (the area under the bar stays empty). So a
        // card blown up to full screen lines up with the page behind it, and
        // swapping one for the other is invisible.
        Color(.systemBackground)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .top) {
                if let image = tab.snapshot {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width)
                        .padding(.top, contentTop)
                } else {
                    placeholder
                        .background(Color(.secondarySystemBackground))
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                // Gone once the corners are square, so a full-screen card has
                // no outline.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
                    .opacity(min(1, cornerRadius / StackMetrics.cornerRadius))
            }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: tab.isBlank ? "safari" : "globe")
                .font(.system(size: 34, weight: .light))
            Text(tab.isBlank ? "New Tab" : tab.displayName)
                .font(.footnote)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The site's icon, always shown, plus the page title beside it that fades
    /// in only on the focused card.
    private var header: some View {
        HStack(spacing: 8) {
            favicon
                .frame(width: faviconSize, height: faviconSize)

            Text(tab.title?.isEmpty == false ? tab.title! : tab.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .opacity(focus)
        }
        // Puts the icon's *center* `faviconInset` from the card's left edge.
        .padding(.leading, faviconInset - faviconSize / 2)
        // Anything longer than the card is cut off with an ellipsis.
        .frame(width: size.width, alignment: .leading)
    }

    @ViewBuilder
    private var favicon: some View {
        if let icon = tab.favicon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 5, style: .continuous))
        } else {
            // No icon (yet): a letter badge in its place.
            Text(String(tab.displayName.first ?? "•").uppercased())
                .font(.system(size: 10, weight: .bold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary, in: .circle)
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .frame(width: 30, height: 30)
                .background(.regularMaterial, in: .circle)
                // A bigger invisible tap area around the small circle.
                .padding(10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(focus)
        .allowsHitTesting(focus > 0.5)
        .accessibilityLabel("Close tab")
    }

    // MARK: - Swipe up to close

    private var swipeToClose: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if isVerticalDrag == nil {
                    isVerticalDrag = abs(value.translation.height) > abs(value.translation.width)
                }
                guard isVerticalDrag == true else { return }
                // Only upward; a downward pull is ignored.
                dragOffset = min(0, value.translation.height)
            }
            .onEnded { value in
                defer { isVerticalDrag = nil }
                guard isVerticalDrag == true else { return }

                // "Predicted" includes momentum, so a quick flick also counts.
                let flick = value.predictedEndTranslation.height
                if dragOffset < -closeDistance || flick < -400 {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragOffset = -700
                    } completion: {
                        onClose()
                    }
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
                        dragOffset = 0
                    }
                }
            }
    }
}
