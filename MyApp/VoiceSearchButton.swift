import SwiftUI

struct VoiceSearchButton: UIViewRepresentable {
    let isRecording: Bool
    let isEnabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> HoldButton {
        let button = HoldButton(type: .custom)
        button.accessibilityLabel = "Voice search"
        button.accessibilityHint = "Hold while speaking, then release to Google search. With VoiceOver, double-tap to start and again to search."
        return button
    }

    func updateUIView(_ button: HoldButton, context: Context) {
        button.onPress = onPress
        button.onRelease = onRelease
        button.onCancel = onCancel
        button.isVoiceRecording = isRecording
        button.isEnabled = isEnabled
        button.tintColor = isRecording ? .systemRed : .secondaryLabel
        button.setImage(UIImage(systemName: isRecording ? "mic.fill" : "mic"), for: .normal)
        button.accessibilityValue = isRecording ? "Listening" : "Hold to talk"
    }

    final class HoldButton: UIButton {
        var onPress: (() -> Void)?
        var onRelease: (() -> Void)?
        var onCancel: (() -> Void)?
        var isVoiceRecording = false

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard super.beginTracking(touch, with: event) else { return false }
            onPress?()
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { true }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            super.endTracking(touch, with: event)
            onRelease?()
        }

        override func cancelTracking(with event: UIEvent?) {
            super.cancelTracking(with: event)
            onCancel?()
        }

        override func accessibilityActivate() -> Bool {
            guard isEnabled else { return false }
            if isVoiceRecording { onRelease?() } else { onPress?() }
            return true
        }
    }
}
