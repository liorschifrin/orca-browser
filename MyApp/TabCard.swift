import SwiftUI

/// One tab in the switcher: a picture of the page, a close button, a title.
/// Swipe it sideways to close it.
struct TabCard: View {
    let tab: Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    /// How far the finger has dragged the card sideways.
    @State private var dragOffset: CGFloat = 0

    private let cornerRadius: CGFloat = 20
    /// Past this much sideways travel, letting go closes the tab.
    private let closeDistance: CGFloat = 110

    var body: some View {
        VStack(spacing: 8) {
            thumbnail
                .overlay(alignment: .topTrailing) { closeButton }

            Text(tab.title?.isEmpty == false ? tab.title! : tab.displayName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .offset(x: dragOffset)
        // Fade as it travels, so it's clear the card is going away.
        .opacity(1 - min(abs(dragOffset) / 300, 0.6))
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        // simultaneousGesture lets the grid keep scrolling vertically while
        // we also watch for sideways drags on the card.
        .simultaneousGesture(swipeToClose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Close tab", onClose)
    }

    // MARK: - Pieces

    private var thumbnail: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(0.62, contentMode: .fit)
            .overlay(alignment: .top) {
                if let image = tab.snapshot {
                    // Fill the card and crop from the bottom, so you see the
                    // top of the page like in the real app.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), lineWidth: isSelected ? 3 : 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: tab.isBlank ? "safari" : "globe")
                .font(.system(size: 30, weight: .light))
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
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: .circle)
                // A bigger invisible tap area around the small circle.
                .padding(8)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close tab")
    }

    // MARK: - Swipe to close

    private var swipeToClose: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Only follow mostly-sideways drags; vertical ones are scrolling.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                // "Predicted" includes momentum, so a quick flick also counts.
                let travel = value.predictedEndTranslation.width
                let shouldClose = abs(dragOffset) > closeDistance || abs(travel) > 280

                if shouldClose, dragOffset != 0 {
                    let direction: CGFloat = dragOffset > 0 ? 1 : -1
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
                    withAnimation(.easeOut(duration: 0.18)) {
                        dragOffset = direction * 500
                    } completion: {
                        onClose()
                    }
                } else {
                    withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                        dragOffset = 0
                    }
                }
            }
    }
}
