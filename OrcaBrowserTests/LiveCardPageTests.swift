import Testing
import Combine
import SwiftUI
import WebKit
@testable import OrcaBrowser

/// A card showing the live page at full expansion, laid out like the switcher's.
@MainActor
final class CardPageModel: ObservableObject { @Published var inCard = true; @Published var expand: CGFloat = 1 }

struct CardPageRoot: View {
    let web: WKWebView
    @ObservedObject var model: CardPageModel
    let barHeight: CGFloat
    let bottomInset: CGFloat
    let topInset: CGFloat
    let screen: CGSize
    var body: some View {
        let metrics = StackMetrics(screen: screen, topInset: topInset)
        ZStack(alignment: .topLeading) {
            if model.inCard {
                let size = metrics.cardSize
                let widthScale = size.width / screen.width
                let pageH = max(1, screen.height - metrics.contentTop / widthScale - bottomInset - barHeight)
                let layout = CardPreviewLayout(cardSize: size, pageSize: CGSize(width: screen.width, height: pageH), contentTop: metrics.contentTop, expansion: model.expand)
                Color.black
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        LiveCardPage(webView: web)
                            .frame(width: layout.pageSize.width, height: layout.pageSize.height)
                            .scaleEffect(layout.scale, anchor: .topLeading)
                            .frame(width: size.width, height: layout.height, alignment: .topLeading)
                            .clipped()
                            .padding(.top, layout.topInset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    .modifier(StackEffect(relative: 0, entrance: 1, expand: model.expand, startTilt: 0, metrics: metrics))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

@MainActor
struct LiveCardPageTests {
    /// A card sits at a smaller scale, so UIKit thinks the page overlaps the
    /// status bar. The page must not hear about it: it would push its sticky
    /// headers down while in the card and snap them back on returning.
    @Test func aPageInACardSeesNoSafeArea() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let web = PageWebView(frame: .zero)
        let model = CardPageModel()
        let root = CardPageRoot(web: web, model: model, barHeight: 69, bottomInset: window.safeAreaInsets.bottom, topInset: window.safeAreaInsets.top, screen: window.bounds.size)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        web.loadHTMLString("<html><head><meta name=viewport content='width=device-width, viewport-fit=cover'></head><body style='margin:0'><div id=e style='padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom)'></div><div id=m style='height:40px;background:red'>top</div><div style='height:5000px'>x</div></body></html>", baseURL: nil)
        for _ in 0..<50 { if !web.isLoading { break }; try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(600))

        func envTop() async -> String? {
            try? await web.evaluateJavaScript("getComputedStyle(document.getElementById('e')).paddingTop") as? String
        }
        #expect(web.safeAreaInsets == .zero)
        #expect(await envTop() == "0px")

        model.inCard = false
        try await Task.sleep(for: .milliseconds(300))
        // Back in the browser the page hears about its real safe area again.
        #expect(!web.ignoresSafeArea)
    }
}
