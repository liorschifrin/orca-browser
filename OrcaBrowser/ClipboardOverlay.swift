import SwiftUI

/// Shows the clipboard button, panel and chip in a window of their own, above
/// everything including sheets, so they are there wherever the keyboard is.
/// The window lets every touch through except those on the button, panel and
/// chip, and never takes the keyboard from the field being typed in.
@MainActor
@Observable
final class ClipboardOverlay {
    static let shared = ClipboardOverlay()

    /// The search field is up; it has its own button and panel.
    var isSuppressed = false

    @ObservationIgnored private var window: UIWindow?
    @ObservationIgnored private weak var historyController: UIViewController?

    private init() {}

    private var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    /// Safe to call again; it only builds the window once, when a scene exists.
    func install() {
        guard window == nil, let scene else { return }
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: ClipboardOverlayContent(onHitRegionsChange: { [weak window] regions in
            window?.hitRegions = regions
        }))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        // Visible but never key, so the field keeps the keyboard.
        window.isHidden = false
        self.window = window
    }

    /// The full list, on top of whatever is showing (a sheet included).
    func showAll() {
        guard historyController?.presentingViewController == nil,
              var top = scene?.windows.first(where: { $0 !== window && $0.isKeyWindow })?.rootViewController
        else { return }
        while let presented = top.presentedViewController { top = presented }
        let controller = UIHostingController(rootView: ClipboardHistoryView(onDone: { [weak self] in
            self?.historyController?.dismiss(animated: true)
        }))
        historyController = controller
        top.present(controller, animated: true)
    }
}

private final class PassthroughWindow: UIWindow {
    var hitRegions: [CGRect] = []

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // SwiftUI may return its hosting view even for a button. Gate by the
        // controls' actual bounds rather than the identity of that view.
        guard hitRegions.contains(where: { $0.contains(point) }) else { return nil }
        return super.hitTest(point, with: event)
    }
}

struct ClipboardHitRegions: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func clipboardHitRegion() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ClipboardHitRegions.self,
                    value: [geometry.frame(in: .global)]
                )
            }
        }
    }
}

private struct ClipboardOverlayContent: View {
    let onHitRegionsChange: ([CGRect]) -> Void
    private let overlay = ClipboardOverlay.shared
    private let history = ClipboardHistory.shared
    private let settings = AppSettings.shared

    var body: some View {
        ZStack {
            ClipboardFloating(
                isEnabled: settings.savesClipboardHistory && !overlay.isSuppressed,
                onSelect: { history.insert($0) },
                onPasteClipboard: { text in
                    // Not from the history, so the system paste is the fallback.
                    if !ClipboardHistory.typeIntoField(text) { ClipboardHistory.pasteIntoField() }
                },
                onShowAll: overlay.showAll
            )
            ZStack {
                if let notice = history.notice {
                    ClipboardNoticeChip(notice: notice)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(notice.id)
                }
            }
            .animation(.snappy, value: history.notice)
            .allowsHitTesting(false)
        }
        .onPreferenceChange(ClipboardHitRegions.self, perform: onHitRegionsChange)
    }
}
