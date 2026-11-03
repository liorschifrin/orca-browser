import SwiftUI
import WebKit

/// Bridges a UIKit view (WKWebView) into SwiftUI.
///
/// SwiftUI can't show a UIKit view directly. `UIViewRepresentable` is the
/// adapter: SwiftUI asks it for a UIView once, then asks it to update that
/// view whenever our SwiftUI state changes.
///
/// Every tab has its own host, and all of them stay in the view tree. Only
/// the active tab is visible. Because no web view is ever removed and re-added,
/// scroll position and page state can't be lost when switching tabs.
struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    let isActive: Bool
    /// Keeps a tab that isn't active on screen, while it slides away.
    var keepsVisible = false
    var onPreviewLink: ((URL) -> Void)?
    var onVisible: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WebViewContainer {
        WebViewContainer()
    }

    func updateUIView(_ container: WebViewContainer, context: Context) {
        // The Tab owns the web view, and replaces it if the tab was unloaded
        // and brought back; show whichever one it has now.
        context.coordinator.attach(to: webView)
        container.show(webView)
        // Hidden views take no touches and cost almost nothing to render.
        webView.isHidden = !(isActive || keepsVisible)
        context.coordinator.onPreviewLink = isActive ? onPreviewLink : nil
        if isActive { onVisible?() }
    }

    static func dismantleUIView(_ container: WebViewContainer, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onPreviewLink: ((URL) -> Void)?
        private weak var attached: WKWebView?

        func attach(to view: WKWebView) {
            guard view !== attached else { return }
            detach()
            // Use an isolated script world and a weak bridge so neither page
            // scripts nor the web view own the browser's preview callback.
            // Adding a name that's already registered throws (and crashes),
            // so clear any handler a previous host left behind first.
            let controller = view.configuration.userContentController
            controller.removeScriptMessageHandler(forName: LinkPress.messageName, contentWorld: .defaultClient)
            controller.add(
                WeakHandler(self), contentWorld: .defaultClient, name: LinkPress.messageName
            )
            attached = view
        }

        func detach() {
            attached?.configuration.userContentController
                .removeScriptMessageHandler(forName: LinkPress.messageName, contentWorld: .defaultClient)
            attached = nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView?.isHidden == false,
                  let address = message.body as? String, let url = URL(string: address),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let onPreviewLink else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onPreviewLink(url)
        }

        private final class WeakHandler: NSObject, WKScriptMessageHandler {
            weak var target: Coordinator?
            init(_ target: Coordinator) { self.target = target }
            func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
                target?.userContentController(userContentController, didReceive: message)
            }
        }
    }
}

/// Holds a web view on screen.
///
/// Web views belong to tabs, and one can move between places: a held link's
/// page starts in the preview and, when opened as a tab, moves into the main
/// browser. So hosts don't hand SwiftUI the web view itself, but a container,
/// and tell it which web view to show. A container takes a given web view
/// once; if another container takes it after that, it lets it go rather than
/// taking it back.
class WebViewContainer: UIView {
    private weak var given: WKWebView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The web view, while it's still in this container.
    var webView: WKWebView? {
        given?.superview === self ? given : nil
    }

    /// Shows `view`, unless it's the one already given. Returns true if it
    /// was newly given.
    @discardableResult
    func show(_ view: WKWebView?) -> Bool {
        guard view !== given else { return false }
        webView?.removeFromSuperview()
        given = view
        guard let view else { return true }
        view.frame = bounds
        addSubview(view)
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView?.frame = bounds
    }

    /// Every tab's container stays in the view tree, stacked on top of each
    /// other. One whose page is hidden must let touches through to the tab
    /// beneath it; an empty view still takes them.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let webView, !webView.isHidden else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Detect the hold inside the page rather than competing with WebKit's
/// built-in drag recognizers. Injected into every frame, including iframes.
enum LinkPress {
    static let messageName = "orcaLinkPreview"
    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart,
                     forMainFrameOnly: false, in: .defaultClient)
    }

    static let source = """
    (() => {
        let timer = null;
        let start = null;
        let activeLink = null;
        let opened = false;
        let suppressClickUntil = 0;
        const linkFor = event => {
            for (const node of event.composedPath()) {
                if (!(node instanceof Element)) continue;
                const link = node.closest('a[href]');
                if (link && /^https?:$/.test(link.protocol)) return link;
            }
            return null;
        };
        const cancel = () => {
            clearTimeout(timer);
            timer = null;
            start = null;
            activeLink = null;
        };
        const installStyle = () => {
            const style = document.createElement('style');
            style.textContent = `a[href], a[href] * {
                -webkit-touch-callout: none !important;
                -webkit-user-drag: none !important;
                -webkit-user-select: none !important;
                user-select: none !important;
                -webkit-tap-highlight-color: transparent !important;
            }`;
            (document.head || document.documentElement).appendChild(style);
        };
        if (document.documentElement) installStyle();
        else document.addEventListener('DOMContentLoaded', installStyle, { once: true });

        document.addEventListener('touchstart', event => {
            cancel();
            opened = false;
            if (event.touches.length !== 1) return;
            activeLink = linkFor(event);
            if (!activeLink) return;
            const touch = event.touches[0];
            start = { x: touch.clientX, y: touch.clientY };
            const address = activeLink.href;
            timer = setTimeout(() => {
                timer = null;
                if (!activeLink?.isConnected) return;
                opened = true;
                const selection = window.getSelection();
                if (selection && (activeLink.contains(selection.anchorNode) ||
                    activeLink.contains(selection.focusNode))) selection.removeAllRanges();
                suppressClickUntil = Date.now() + 1500;
                window.webkit.messageHandlers.orcaLinkPreview.postMessage(address);
            }, 250);
        }, { capture: true, passive: true });
        document.addEventListener('touchmove', event => {
            if (!start) return;
            const touch = event.touches[0];
            if (event.touches.length !== 1 ||
                Math.hypot(touch.clientX - start.x, touch.clientY - start.y) > 10) cancel();
        }, { capture: true, passive: true });
        document.addEventListener('touchend', event => {
            if (opened) {
                event.preventDefault();
                suppressClickUntil = Date.now() + 750;
            }
            cancel();
            opened = false;
        }, { capture: true, passive: false });
        document.addEventListener('touchcancel', () => {
            cancel();
            opened = false;
        }, { capture: true, passive: true });
        document.addEventListener('click', event => {
            if (Date.now() < suppressClickUntil && linkFor(event)) {
                event.preventDefault();
                event.stopImmediatePropagation();
            }
        }, true);
        for (const type of ['dragstart', 'contextmenu']) {
            document.addEventListener(type, event => {
                if (linkFor(event)) event.preventDefault();
            }, true);
        }
        window.addEventListener('pagehide', cancel);
    })();
    """
}

/// One list controls the live peek and its tab card. Adding an action here
/// automatically gives it space in both places.
enum PeekAction {
    case newTab, backgroundTab, copyLink, addToPlay

    /// The actions that apply to the page being peeked.
    static func available(for url: URL) -> [PeekAction] {
        var actions: [PeekAction] = [.newTab, .backgroundTab, .copyLink]
        if Tab.isYouTube(url) { actions.append(.addToPlay) }
        return actions
    }

    var title: String {
        switch self {
        case .newTab: "Open a New Tab"
        case .backgroundTab: "Open in Background Tab"
        case .copyLink: "Copy Link"
        case .addToPlay: AddToPlay.shortcutName
        }
    }

    var icon: String {
        switch self {
        case .newTab: "plus.square"
        case .backgroundTab: "plus.square.on.square"
        case .copyLink: "doc.on.doc"
        case .addToPlay: "text.badge.plus"
        }
    }
}

/// The panel uses equal margins above and below the space above the toolbar.
/// Its web page receives whatever height remains after the action list.
struct PeekLayout {
    static let margin: CGFloat = 24
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 48
    static let minimumPageHeight: CGFloat = 100

    let size: CGSize
    let bottomInset: CGFloat
    let actions: [PeekAction]

    var panelWidth: CGFloat { max(1, min(380, size.width - 2 * Self.margin)) }
    var panelHeight: CGFloat { max(1, size.height - bottomInset - 2 * Self.margin) }
    var panelCenter: CGPoint {
        CGPoint(x: size.width / 2, y: Self.margin + panelHeight / 2)
    }
    var actionsHeight: CGFloat {
        let count = CGFloat(actions.count)
        let natural = count * Self.rowHeight + max(0, count - 1)
        return min(natural, max(0, panelHeight - Self.headerHeight - Self.minimumPageHeight))
    }
}

/// Shared structure for the live peek and its exact tab-card representation.
struct PeekPanel<Page: View>: View {
    let address: URL
    let layout: PeekLayout
    let page: Page
    let onOpen: () -> Void
    let onClose: () -> Void
    let onAction: (PeekAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onOpen) {
                    HStack(spacing: 8) {
                        Text(address.host() ?? address.absoluteString)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(address.host() ?? address.absoluteString)")

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 44, height: PeekLayout.headerHeight)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close preview")
            }
            .frame(height: PeekLayout.headerHeight)

            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(layout.actions.enumerated()), id: \.offset) { index, action in
                        if index > 0 { Divider() }
                        Button { onAction(action) } label: {
                            HStack {
                                Text(action.title)
                                Spacer()
                                Image(systemName: action.icon)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: PeekLayout.rowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: layout.actionsHeight)
        }
        .frame(width: layout.panelWidth, height: layout.panelHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 20)
    }
}

/// A popup with an interactive page. The toolbar remains above the tint and
/// accepts taps while the peek is open.
struct LinkPreview: View {
    let url: URL
    let previewTab: Tab
    let bottomInset: CGFloat
    let animateEntrance: Bool
    let onPresented: () -> Void
    let onOpenNewTab: () -> Void
    let onOpenBackground: () -> Void
    let onOpen: (URL) -> Void
    let onDismiss: () -> Void
    @State private var isVisible: Bool
    @State private var isClosing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL, previewTab: Tab, bottomInset: CGFloat, animateEntrance: Bool,
         onPresented: @escaping () -> Void, onOpenNewTab: @escaping () -> Void,
         onOpenBackground: @escaping () -> Void, onOpen: @escaping (URL) -> Void,
         onDismiss: @escaping () -> Void) {
        self.url = url
        self.previewTab = previewTab
        self.bottomInset = bottomInset
        self.animateEntrance = animateEntrance
        self.onPresented = onPresented
        self.onOpenNewTab = onOpenNewTab
        self.onOpenBackground = onOpenBackground
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        _isVisible = State(initialValue: !animateEntrance)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = PeekLayout(size: geometry.size, bottomInset: bottomInset, actions: PeekAction.available(for: currentURL))
            ZStack {
                Color.black.opacity(isVisible ? 0.35 : 0)
                    .ignoresSafeArea()
                    .padding(.bottom, bottomInset)
                    .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .padding(.bottom, bottomInset)
                    .onTapGesture { close(onDismiss) }
                    .accessibilityLabel("Dismiss preview")

                PeekPanel(
                    address: currentURL, layout: layout,
                    page: ZStack {
                        Color(uiColor: .systemBackground)
                        PreviewPageHost(tab: previewTab, url: url)
                        if previewTab.isRestoring, let image = previewTab.snapshot {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipped()
                                .allowsHitTesting(false)
                        }
                        ProgressLine(tab: previewTab)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .allowsHitTesting(false)
                        if let error = previewTab.loadError {
                            Text(error.message)
                                .foregroundStyle(.primary)
                                .padding()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.background)
                        }
                    },
                    onOpen: {
                        let address = currentURL
                        close { onOpen(address) }
                    },
                    onClose: { close(onDismiss) },
                    onAction: handleAction
                )
                .position(layout.panelCenter)
                .scaleEffect(reduceMotion || isVisible ? 1 : 0.92)
                .opacity(isVisible ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            previewTab.activate()
            onPresented()
            if animateEntrance {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.82)) {
                    isVisible = true
                }
            }
        }
        .allowsHitTesting(!isClosing)
    }

    private var currentURL: URL { previewTab.url ?? url }

    private func close(_ completion: @escaping () -> Void) {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.easeOut(duration: 0.16), completionCriteria: .removed) {
            isVisible = false
        } completion: {
            completion()
        }
    }

    private func promote(inBackground: Bool) {
        close {
            if previewTab.isBlank { previewTab.load(url) }
            if inBackground { onOpenBackground() }
            else { onOpenNewTab() }
        }
    }

    private func handleAction(_ action: PeekAction) {
        switch action {
        case .newTab: promote(inBackground: false)
        case .backgroundTab: promote(inBackground: true)
        case .copyLink:
            UIPasteboard.general.url = currentURL
            close(onDismiss)
        case .addToPlay:
            AddToPlay.run(with: currentURL)
            close(onDismiss)
        }
    }
}

/// Gives the preview a concrete UIKit viewport before starting navigation.
/// The preview does not use the main tab host or its gesture recognizer.
private struct PreviewPageHost: UIViewRepresentable {
    let tab: Tab
    let url: URL

    func makeUIView(context: Context) -> PreviewViewport {
        PreviewViewport(tab: tab, url: url)
    }

    func updateUIView(_ uiView: PreviewViewport, context: Context) {
        uiView.attachWebView()
    }

    final class PreviewViewport: WebViewContainer {
        private let tab: Tab
        private let url: URL
        private var hasStarted = false

        init(tab: Tab, url: URL) {
            self.tab = tab
            self.url = url
            super.init(frame: .zero)
            backgroundColor = .systemBackground
            attachWebView()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        func attachWebView() {
            if let webView = tab.webView, show(webView) {
                webView.isHidden = false
                setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // A new preview's tab has no web view until it loads something, so
            // don't wait for one here: loading is what creates it.
            guard !hasStarted, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            hasStarted = true
            // Avoid publishing observable tab changes during SwiftUI layout.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.tab.isBlank else { return }
                self.tab.load(self.url)
                self.attachWebView()
            }
        }
    }
}
