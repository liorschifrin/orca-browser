import SwiftUI

struct PopupListItem: Identifiable, Equatable {
    let id: String
    let title: String
}

/// A button that opens a list of choices above it the moment it's touched
/// (unlike the back button, there's no wait). Two ways to choose: slide to a
/// row and let go, or let go on the button, which leaves the list open, and
/// tap a row. A touch outside closes it.
struct PopupListButton<Label: View>: View {
    typealias Item = PopupListItem

    /// Bottom row first.
    let items: [PopupListItem]
    let selectedID: String?
    let onSelect: (PopupListItem) -> Void
    @ViewBuilder let label: () -> Label

    @State private var isOpen = false
    @State private var isPinned = false
    @State private var highlighted: Int?
    @State private var ignoreTouch = false
    @State private var isPressed = false
    @State private var buttonFrame = CGRect.zero
    @State private var listFrame = CGRect.zero
    @State private var feedback = UIImpactFeedbackGenerator(style: .medium)

    private static var rowHeight: CGFloat { 40 }
    private static var listWidth: CGFloat { 104 }
    /// Space between the top of the button and the bottom of the list.
    private static var gap: CGFloat { 8 }

    var body: some View {
        label()
            .scaleEffect(isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: isPressed)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { buttonFrame = $0 }
            .overlay(alignment: .topLeading) {
                if isOpen {
                    list
                        .offset(x: listLeading, y: -(listHeight + Self.gap))
                        .transition(.opacity)
                        .allowsHitTesting(isPinned)
                }
            }
            .background {
                OutsideTouchCloser(isActive: isPinned, insideFrame: listFrame) { close() }
            }
            .overlay {
                TouchSurface(
                    onBegan: { _ in touchBegan() },
                    onMoved: { point in touchMoved(to: point) },
                    onEnded: { point in touchEnded(at: point) },
                    onCancelled: { cancelTouch() }
                )
            }
    }

    // MARK: - Layout

    private var listHeight: CGFloat { CGFloat(items.count) * Self.rowHeight }

    /// Where the list's left edge is, relative to the button's: centered over
    /// it, kept inside the screen.
    private var listLeading: CGFloat {
        let screen = UIScreen.main.bounds.width
        let wanted = buttonFrame.midX - Self.listWidth / 2
        let left = min(max(8, wanted), screen - Self.listWidth - 8)
        return left - buttonFrame.minX
    }

    /// The row under a point relative to the button (0 = bottom), or nil.
    private func row(at point: CGPoint) -> Int? {
        guard point.x > listLeading - 20, point.x < listLeading + Self.listWidth + 20 else { return nil }
        let above = -point.y - Self.gap
        guard above >= 0 else { return nil }
        let index = Int(above / Self.rowHeight)
        return index < items.count ? index : nil
    }

    /// The row under a point relative to the (pinned) list, or nil.
    private func pinnedRow(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.x <= Self.listWidth, point.y >= 0, point.y <= listHeight else { return nil }
        return min(items.count - 1, Int((listHeight - point.y) / Self.rowHeight))
    }

    // MARK: - Touches

    private func touchBegan() {
        if isPinned {
            close()
            ignoreTouch = true
            return
        }
        ignoreTouch = false
        isPressed = true
        feedback.prepare()
        open()
    }

    private func touchMoved(to point: CGPoint) {
        if ignoreTouch { return }
        highlight(row(at: point))
    }

    private func touchEnded(at point: CGPoint) {
        if ignoreTouch { return }
        isPressed = false
        if let index = row(at: point) {
            choose(index)
        } else {
            // Let go on the button, or away from the rows: stay open to tap from.
            highlighted = nil
            isPinned = true
        }
    }

    private func cancelTouch() {
        isPressed = false
        close()
    }

    // MARK: - List

    private func open() {
        guard !isOpen, !items.isEmpty else { return }
        feedback.impactOccurred()
        highlighted = nil
        withAnimation(.easeOut(duration: 0.12)) { isOpen = true }
    }

    private func close() {
        isPinned = false
        highlighted = nil
        withAnimation(.easeOut(duration: 0.12)) { isOpen = false }
    }

    private func choose(_ index: Int) {
        if items.indices.contains(index) { onSelect(items[index]) }
        close()
    }

    private func highlight(_ index: Int?) {
        if index != highlighted {
            highlighted = index
            if index != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            // Reversed so the first item is the bottom row.
            ForEach(Array(items.enumerated()).reversed(), id: \.element.id) { index, item in
                let isCurrent = item.id == selectedID
                Text(item.title)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    .lineLimit(1)
                    .frame(width: Self.listWidth, height: Self.rowHeight)
                    .background {
                        if isCurrent {
                            Color.black.opacity(0.75)
                        } else if index == highlighted {
                            Color.accentColor.opacity(0.35)
                        }
                    }
            }
        }
        .background(.regularMaterial)
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { listFrame = $0 }
        // Once pinned open, touches on the list itself: slide to highlight,
        // let go to choose (or just tap a row).
        .overlay {
            if isPinned {
                TouchSurface(
                    onBegan: { point in highlight(pinnedRow(at: point)) },
                    onMoved: { point in highlight(pinnedRow(at: point)) },
                    onEnded: { point in
                        if let index = pinnedRow(at: point) { choose(index) } else { highlighted = nil }
                    },
                    onCancelled: { highlighted = nil }
                )
            }
        }
    }
}
