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
    var onPreviewLink: ((URL) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        // We don't create a web view here; the Tab already owns one.
        // We just hand that same instance to SwiftUI.
        context.coordinator.onPreviewLink = onPreviewLink
        context.coordinator.attach(to: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Hidden views take no touches and cost almost nothing to render.
        uiView.isHidden = !isActive
        context.coordinator.onPreviewLink = isActive ? onPreviewLink : nil
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: LinkPress.messageName, contentWorld: .defaultClient)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onPreviewLink: ((URL) -> Void)?

        func attach(to view: WKWebView) {
            // Use an isolated script world and a weak bridge so neither page
            // scripts nor the web view own the browser's preview callback.
            view.configuration.userContentController.add(
                WeakHandler(self), contentWorld: .defaultClient, name: LinkPress.messageName
            )
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

/// Detect the hold inside the page rather than competing with WebKit's
/// built-in drag recognizers. Injected into every frame, including iframes.
enum LinkPress {
    static let messageName = "barkLinkPreview"
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
                window.webkit.messageHandlers.barkLinkPreview.postMessage(address);
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

/// A popup with an interactive page and explicit buttons for opening it.
struct LinkPreview: View {
    let url: URL
    let onOpenNewTab: (Tab) -> Void
    let onOpenBackground: (Tab) -> Void
    let onOpen: (URL) -> Void
    let onDismiss: () -> Void
    @State private var previewTab: Tab?
    @State private var isVisible = false
    @State private var isClosing = false
    @State private var wasPromoted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL, onOpenNewTab: @escaping (Tab) -> Void, onOpenBackground: @escaping (Tab) -> Void,
         onOpen: @escaping (URL) -> Void, onDismiss: @escaping () -> Void) {
        self.url = url
        self.onOpenNewTab = onOpenNewTab
        self.onOpenBackground = onOpenBackground
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(isVisible ? 0.35 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { close(onDismiss) }
                    .accessibilityLabel("Dismiss preview")
                VStack(spacing: 0) {
                    HStack {
                        Text(currentURL.host() ?? currentURL.absoluteString)
                            .font(.subheadline).lineLimit(1)
                        Spacer()
                        Button(action: { close(onDismiss) }) { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Close preview")
                    }
                    .padding(12)

                    ZStack {
                        Color(uiColor: .systemBackground)
                        if let previewTab {
                            PreviewPageHost(tab: previewTab, url: url)
                        }
                        if let error = previewTab?.loadError {
                            Text(error.message)
                                .foregroundStyle(.primary)
                                .padding()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.background)
                        }
                    }
                    .frame(height: max(100, geometry.size.height - 308))
                    .clipped()

                    VStack(spacing: 0) {
                        action("Open a New Tab", icon: "plus.square") { promote(inBackground: false) }
                        Divider()
                        action("Open in Background Tab", icon: "plus.square.on.square") { promote(inBackground: true) }
                        Divider()
                        action("Open", icon: "arrow.up.right") {
                            let address = currentURL
                            close { onOpen(address) }
                        }
                        Divider()
                        action("Copy Link", icon: "doc.on.doc") {
                            UIPasteboard.general.url = currentURL
                            close(onDismiss)
                        }
                    }
                }
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(radius: 20)
                .frame(width: max(1, min(380, geometry.size.width - 48)))
                .padding(24)
                .scaleEffect(reduceMotion || isVisible ? 1 : 0.92)
                .opacity(isVisible ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if previewTab == nil { previewTab = Tab() }
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.82)) {
                isVisible = true
            }
        }
        .allowsHitTesting(!isClosing)
        .onDisappear {
            // Once adopted, the store owns this page. Dismissing the popup
            // must not stop loading or discard the promoted web view.
            if !wasPromoted { previewTab?.teardown() }
            previewTab = nil
        }
        .accessibilityAddTraits(.isModal)
    }

    private var currentURL: URL { previewTab?.url ?? url }

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
        guard let previewTab else { return }
        close {
            // The button can be pressed before the preview's first layout.
            if previewTab.isBlank { previewTab.load(url) }
            wasPromoted = true
            previewTab.webView?.removeFromSuperview()
            if inBackground { onOpenBackground(previewTab) }
            else { onOpenNewTab(previewTab) }
        }
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: icon)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    func updateUIView(_ uiView: PreviewViewport, context: Context) {}

    final class PreviewViewport: UIView {
        private let tab: Tab
        private let url: URL
        private var hasStarted = false

        init(tab: Tab, url: URL) {
            self.tab = tab
            self.url = url
            super.init(frame: .zero)
            backgroundColor = .systemBackground
            clipsToBounds = true
            if let webView = tab.webView {
                webView.isHidden = false
                addSubview(webView)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // SwiftUI may still lay out the exiting popup after its web view
            // has moved into the main browser. Never resize that adopted view.
            guard let webView = tab.webView, webView.superview === self else { return }
            webView.frame = bounds
            guard !hasStarted, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            hasStarted = true
            // Avoid publishing observable tab changes during SwiftUI layout.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.tab.isBlank else { return }
                self.tab.load(self.url)
            }
        }
    }
}
