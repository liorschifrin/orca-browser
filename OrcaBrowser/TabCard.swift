import SwiftUI
import WebKit

/// One tab in the switcher: a picture of the page, with the site's icon above
/// it (and, for the focused card only, the page title beside the icon).
/// Swipe it up to close it, like closing an app in the iOS app switcher.
///
/// The card knows nothing about where it sits in the deck; `StackEffect`
/// positions, scales and tilts it from outside. The card's own box is exactly
/// the thumbnail, and the header floats above that box.
struct TabCard: View, Equatable {
    let tab: Tab
    let barHeight: CGFloat
    let size: CGSize
    let screenSize: CGSize
    let safeBottomInset: CGFloat
    /// How far the favicon's center sits in from the card's left edge.
    let faviconInset: CGFloat
    /// How far down the card the page picture starts (the status bar's share).
    let contentTop: CGFloat
    /// 1 when this card is the focused one, fading to 0 as it moves away.
    /// Controls the title and close button, which only the focused card shows.
    let focus: Double
    /// True for the most recent tab, whose real page runs in the card (a
    /// video keeps playing) instead of a picture of it.
    let showsLivePage: Bool
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

    /// Ignores the closures, which can't be compared; they always act on
    /// the same tab. What the tab itself shows is tracked separately, by
    /// observation.
    static func == (a: TabCard, b: TabCard) -> Bool {
        a.tab === b.tab && a.barHeight == b.barHeight && a.size == b.size
            && a.screenSize == b.screenSize && a.safeBottomInset == b.safeBottomInset
            && a.faviconInset == b.faviconInset && a.contentTop == b.contentTop
            && a.focus == b.focus && a.showsLivePage == b.showsLivePage
    }

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
            .accessibilityLabel((tab.isIncognito ? "Incognito, " : "") + (tab.title?.isEmpty == false ? tab.title! : tab.displayName))
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
                TabPicture(tab: tab) { image in
                    if tab.isIncognito {
                        // Private pages show no picture at all, only this haze.
                        incognitoFill
                    } else if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size.width)
                            .padding(.top, contentTop)
                    } else if !tab.hasSnapshot {
                        placeholder
                            .background(Color(.secondarySystemBackground))
                    }
                }
            }
            .overlay {
                if showsLivePage, !tab.isIncognito, !tab.isBlank, !tab.isRestoring,
                   tab.loadError == nil, let webView = tab.webView {
                    livePage(webView)
                }
            }
            .overlay {
                if let peek = tab.peek {
                    peekThumbnail(peek)
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
            // The shadow comes from a plain shape behind the card rather than
            // the card itself: the same look (the card is opaque), but far
            // cheaper to redraw on every frame of the deck's animations.
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
            }
    }

    /// A soft grey-blue-teal wash, standing in for the page.
    private var incognitoFill: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.29, green: 0.29, blue: 0.30), location: 0),
                .init(color: Color(red: 0.18, green: 0.20, blue: 0.34), location: 0.2),
                .init(color: Color(red: 0.33, green: 0.33, blue: 0.34), location: 0.45),
                .init(color: Color(red: 0.31, green: 0.33, blue: 0.34), location: 0.75),
                .init(color: Color(red: 0.20, green: 0.31, blue: 0.36), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The running page at full-screen size, scaled down into the card. It
    /// takes the same place and size the browser gives it, so nothing in the
    /// page reflows when it moves in or out.
    private func livePage(_ webView: WKWebView) -> some View {
        let scale = size.width / max(1, screenSize.width)
        let topInset = contentTop / scale
        let height = max(1, screenSize.height - topInset - safeBottomInset - barHeight)

        return LiveCardPage(webView: webView)
            .frame(width: screenSize.width, height: height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width, height: height * scale, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, contentTop)
            .allowsHitTesting(false)
    }

    private func peekThumbnail(_ peek: Tab.Peek) -> some View {
        let scale = size.width / max(1, screenSize.width)
        let topInset = contentTop / scale
        let layout = PeekLayout(
            size: CGSize(width: screenSize.width,
                         height: max(1, screenSize.height - topInset - safeBottomInset)),
            bottomInset: barHeight,
            actions: PeekAction.available(for: peek.tab.url ?? peek.url)
        )

        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.35)
                .frame(width: layout.size.width, height: max(0, layout.size.height - barHeight))

            PeekPanel(
                address: peek.tab.url ?? peek.url,
                layout: layout,
                page: ZStack {
                    Color(uiColor: .systemBackground)
                    TabPicture(tab: peek.tab) { image in
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                        }
                    }
                },
                onOpen: {}, onClose: {}, onAction: { _ in }
            )
            .position(layout.panelCenter)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: size.width, height: layout.size.height * scale, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, contentTop)
        .allowsHitTesting(false)
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

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title?.isEmpty == false ? tab.title! : tab.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if tab.isIncognito {
                    Text("Incognito Tab")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(focus)
        }
        // Puts the icon's *center* `faviconInset` from the card's left edge.
        .padding(.leading, faviconInset - faviconSize / 2)
        // Anything longer than the card is cut off with an ellipsis.
        // A fixed height keeps the icon where it was when a second line
        // (Incognito Tab) is added; the text spills out evenly around it.
        .frame(width: size.width, height: faviconSize, alignment: .leading)
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
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
                    withAnimation(.easeOut(duration: 0.12)) {
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
