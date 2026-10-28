import SwiftUI

/// One tab in the switcher: a picture of the page, a close button, a title.
/// Swipe it up to close it, like closing an app in the iOS app switcher.
struct TabCard: View {
    let tab: Tab
    let size: CGSize
    /// True while this card's picture is being drawn by the zoom animation
    /// instead, so we don't draw it twice.
    let thumbnailHidden: Bool
    /// Reports where the thumbnail is on screen (used to start/end the zoom).
    let reportFrame: (CGRect) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void

    /// How far the finger has dragged the card upward (zero or negative).
    @State private var dragOffset: CGFloat = 0
    /// Whether the current drag is vertical. Decided once, at the start, so
    /// a drag that begins sideways (browsing) never turns into a close.
    @State private var isVerticalDrag: Bool?

    static let cornerRadius: CGFloat = 24
    /// Past this much upward travel, letting go closes the tab.
    private let closeDistance: CGFloat = 120

    var body: some View {
        VStack(spacing: 12) {
            thumbnail
                .opacity(thumbnailHidden ? 0 : 1)
                .overlay(alignment: .topTrailing) { closeButton }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named("switcher"))
                } action: { reportFrame($0) }

            Text(tab.title?.isEmpty == false ? tab.title! : tab.displayName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(width: size.width)
        }
        .offset(y: dragOffset)
        // Fade and shrink a little as it rises, so it's clear it's going away.
        .opacity(1 - min(abs(dragOffset) / 400, 0.7))
        .scaleEffect(1 - min(abs(dragOffset) / 1500, 0.15))
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        // simultaneousGesture lets the carousel keep scrolling sideways while
        // we also watch for upward drags on the card.
        .simultaneousGesture(swipeToClose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Close tab", onClose)
    }

    // MARK: - Pieces

    private var thumbnail: some View {
        Color(.secondarySystemBackground)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .top) {
                if let image = tab.snapshot {
                    // Fill the card and crop from the bottom, so you see the
                    // top of the page.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
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
