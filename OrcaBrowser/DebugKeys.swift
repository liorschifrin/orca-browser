#if DEBUG
import UIKit

/// Simulator testing: types `-debugKeys` ("<" is delete) into the focused
/// field through UIKit, as the keyboard would, and logs the field after each key.
enum DebugKeys {
    private static weak var found: UIResponder?

    static func replay() async {
        guard let keys = UserDefaults.standard.string(forKey: "debugKeys") else { return }
        try? await Task.sleep(for: .seconds(1.5))
        for key in keys {
            found = nil
            UIApplication.shared.sendAction(#selector(UIResponder.debugCaptureFirstResponder), to: nil, from: nil, for: nil)
            guard let input = found as? UIKeyInput else { print("DEBUGKEYS no responder"); return }
            if key == "<" { input.deleteBackward() } else { input.insertText(String(key)) }
            try? await Task.sleep(for: .milliseconds(400))
            print("DEBUGKEYS after \(key): \((found as? UITextField)?.text?.debugDescription ?? "?")")
        }
    }

    fileprivate static func capture(_ responder: UIResponder) { found = responder }
}

extension UIResponder {
    @objc func debugCaptureFirstResponder() { DebugKeys.capture(self) }
}
#endif
