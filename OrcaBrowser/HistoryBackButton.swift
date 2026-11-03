import SwiftUI
import WebKit

/// Tap to go back one page. Press and hold (or drag up) to open the
/// tab's whole history above the button: oldest page at the bottom,
/// newest at the top, the current page dark. Slide to an entry and let
/// go to jump there (backward or forward). Letting go elsewhere leaves
/// the list open for another touch.
struct HistoryBackButton: View {
    let tab: Tab
    /// Whether the history list is open. The bar turns its own swipe off
    /// meanwhile, so the two don't compete for the finger.
    @Binding var showHistory: Bool

    @State private var isBackPressed = false
    @State private var highlighted: Int?
    @State private var holdTask: Task<Void, Never>?
    @State private var didMove = false
    @State private var ignoreTouch = false
    @State private var isHistoryPinned = false
    @State private var listFrame = CGRect.zero
    @State private var feedback = UIImpactFeedbackGenerator(style: .medium)

    private static let historyRowHeight: CGFloat = 40
    private static let historyWidth: CGFloat = 260
    private static let historyMaxRows = 11
    /// Space between the top of the button and the bottom of the list.
    private static let historyGap: CGFloat = 8

    var body: some View {
        Image(systemName: "chevron.left")
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .background(.thinMaterial, in: .circle)
            .contentShape(.circle)
            .scaleEffect(isBackPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.2), value: isBackPressed)
            .opacity(tab.canGoBack || tab.canGoForward ? 1 : 0.3)
            .overlay(alignment: .bottomTrailing) {
                if showHistory {
                    historyList
                        .offset(y: -(44 + Self.historyGap))
                        .transition(.opacity)
                        .allowsHitTesting(isHistoryPinned)
                }
            }
            // While pinned open, any touch outside the list closes it, and
            // still carries on to whatever it landed on.
            .background {
                OutsideTouchCloser(isActive: isHistoryPinned, insideFrame: listFrame) {
                    closeHistory()
                }
            }
            // Raw touches, handled by UIKit: SwiftUI's gestures can wait
            // before reporting a finger that is held still.
            .overlay {
                TouchSurface(
                    onBegan: { _ in touchBegan() },
                    onMoved: { point in touchMoved(to: point) },
                    onEnded: { point in touchEnded(at: point) },
                    onCancelled: { cancelTouch() }
                )
            }
            .accessibilityElement()
            .accessibilityLabel("Back")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if tab.canGoBack { tab.goBack() } }
    }

    private func touchBegan() {
        // Touching the button while the list is pinned just closes it.
        if isHistoryPinned {
            closeHistory()
            ignoreTouch = true
            return
        }
        ignoreTouch = false
        isBackPressed = true
        didMove = false
        feedback.prepare()
        holdTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            openHistory()
        }
    }

    private func touchMoved(to point: CGPoint) {
        if ignoreTouch { return }
        // Dragging off the button opens it without waiting.
        if !showHistory, hypot(point.x - 22, point.y - 22) > 14 {
            didMove = true
            holdTask?.cancel()
            openHistory()
        }
        if showHistory { updateHighlight(at: point) }
    }

    private func touchEnded(at point: CGPoint) {
        if ignoreTouch { return }
        holdTask?.cancel()
        isBackPressed = false
        if showHistory {
            if let index = historyIndex(at: point) {
                jump(toRow: index)
            } else {
                // Let go away from the entries: leave the list open to pick from.
                highlighted = nil
                isHistoryPinned = true
            }
        } else if !didMove, tab.canGoBack {
            tab.goBack()
        }
    }

    private func cancelTouch() {
        holdTask?.cancel()
        isBackPressed = false
        closeHistory()
    }

    private func jump(toRow index: Int) {
        let window = historyWindow
        if window.items.indices.contains(index) {
            tab.go(to: window.items[index])
        }
        closeHistory()
    }

    private func closeHistory() {
        isHistoryPinned = false
        highlighted = nil
        withAnimation(.easeOut(duration: 0.12)) { showHistory = false }
    }

    /// The slice of history that fits on screen, oldest first, kept around
    /// the current page. `current` is its index within `items`.
    private var historyWindow: (items: [WKBackForwardListItem], start: Int, current: Int) {
        let (items, current) = tab.history
        let rows = Self.historyMaxRows
        let start = max(0, min(current - rows / 2, items.count - rows))
        let end = min(items.count, start + rows)
        return (Array(items[start..<end]), start, current - start)
    }

    private func openHistory() {
        guard !showHistory, tab.history.items.count > 1 else { return }
        feedback.impactOccurred()
        highlighted = nil
        withAnimation(.easeOut(duration: 0.12)) { showHistory = true }
    }

    /// Which row is under the finger (0 = bottom row). `point` is relative
    /// to the button.
    private func historyIndex(at point: CGPoint) -> Int? {
        guard point.x > 44 - Self.historyWidth - 20, point.x < 44 + 20 else { return nil }
        let above = -point.y - Self.historyGap
        guard above >= 0 else { return nil }
        let index = Int(above / Self.historyRowHeight)
        return index < historyWindow.items.count ? index : nil
    }

    private func updateHighlight(at point: CGPoint) {
        updateHighlight(toRowAt: historyIndex(at: point))
    }

    private func updateHighlight(toRowAt index: Int?) {
        if index != highlighted {
            highlighted = index
            if index != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    private var historyList: some View {
        let window = historyWindow
        // Reversed so the oldest page is at the bottom, the newest on top.
        return VStack(spacing: 0) {
            ForEach(Array(window.items.enumerated()).reversed(), id: \.offset) { index, item in
                let isCurrent = index == window.current
                Text(item.title?.isEmpty == false ? item.title! : item.url.host() ?? item.url.absoluteString)
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .frame(width: Self.historyWidth, height: Self.historyRowHeight, alignment: .leading)
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
        // Once pinned, touches on the list itself: slide to highlight,
        // let go to jump (or just tap an entry).
        .overlay {
            if isHistoryPinned {
                TouchSurface(
                    onBegan: { point in updateHighlight(toRowAt: pinnedRow(at: point)) },
                    onMoved: { point in updateHighlight(toRowAt: pinnedRow(at: point)) },
                    onEnded: { point in
                        if let row = pinnedRow(at: point) { jump(toRow: row) } else { highlighted = nil }
                    },
                    onCancelled: { highlighted = nil }
                )
            }
        }
    }

    /// Row (0 = bottom) under a point relative to the list, or nil if outside it.
    private func pinnedRow(at point: CGPoint) -> Int? {
        let count = historyWindow.items.count
        let height = CGFloat(count) * Self.historyRowHeight
        guard point.x >= 0, point.x <= Self.historyWidth, point.y >= 0, point.y <= height else { return nil }
        return min(count - 1, Int((height - point.y) / Self.historyRowHeight))
    }
}

/// While active, watches every touch on screen without getting in its way,
/// and calls `onOutside` for those that start outside `insideFrame`
/// (in screen coordinates).
private struct OutsideTouchCloser: UIViewRepresentable {
    let isActive: Bool
    let insideFrame: CGRect
    let onOutside: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.insideFrame = insideFrame
        coordinator.onOutside = onOutside
        // The view may not be in a window yet; look again next pass.
        DispatchQueue.main.async {
            if isActive, let window = view.window {
                coordinator.attach(to: window)
            } else {
                coordinator.detach()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        var insideFrame = CGRect.zero
        var onOutside: () -> Void = {}
        private var recognizer: Observer?

        func attach(to window: UIWindow) {
            guard recognizer == nil else { return }
            let observer = Observer { [weak self] point in
                guard let self, !self.insideFrame.contains(point) else { return }
                // Later, so a touch on the back button itself is handled first.
                DispatchQueue.main.async { self.onOutside() }
            }
            window.addGestureRecognizer(observer)
            recognizer = observer
        }

        func detach() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }
    }

    /// Looks at each new touch, then steps aside (fails) so nothing else is affected.
    final class Observer: UIGestureRecognizer {
        private let handler: (CGPoint) -> Void

        init(handler: @escaping (CGPoint) -> Void) {
            self.handler = handler
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { handler(touch.location(in: nil)) }
            state = .failed
        }
    }
}
