import SwiftUI

/// A transparent view that reports touches straight from UIKit, with
/// positions relative to itself (also while the finger is outside it).
struct TouchSurface: UIViewRepresentable {
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void
    let onCancelled: () -> Void

    func makeUIView(context: Context) -> TouchView { TouchView() }

    func updateUIView(_ view: TouchView, context: Context) {
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.onCancelled = onCancelled
    }

    final class TouchView: UIView {
        var onBegan: (CGPoint) -> Void = { _ in }
        var onMoved: (CGPoint) -> Void = { _ in }
        var onEnded: (CGPoint) -> Void = { _ in }
        var onCancelled: () -> Void = {}

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = false
        }
        required init?(coder: NSCoder) { fatalError() }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first { onBegan(touch.location(in: self)) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first { onMoved(touch.location(in: self)) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let touch = touches.first { onEnded(touch.location(in: self)) }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { onCancelled() }
    }
}
