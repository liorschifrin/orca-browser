import SwiftUI

/// The one and only screen. The page fills the whole display, the bottom
/// bar floats on top of it, and the tab switcher and search overlay float
/// on top of both.
struct BrowserView: View {
    @State private var store: BrowserStore

    @State private var barHeight: CGFloat = 0
    // Search starts open only when there's no page to go back to (a blank tab).
    @State private var isSearching: Bool
    // Set when search was opened by tapping the address: the URL to show,
    // and the submitted text then replaces the current page.
    @State private var editingURL: URL?
    @State private var searchInitialText = ""
    @State private var searchIsIncognito = false
    @State private var searchOpenedFromGoogle = false
    @State private var replaceGoogleSearchOnSubmit = false
    @State private var isSwitching = false
    /// A new value for every time the switcher opens, so SwiftUI never reuses
    /// a switcher that was mid-exit (it would still think it was "leaving").
    @State private var switcherID = UUID()
    @State private var isPreparingSwitcher = false
    /// The switcher is animating away (a card was picked).
    @State private var isExitingSwitcher = false
    /// The tabs button was tapped during that exit: open it again afterwards.
    @State private var reopenAfterExit = false
    /// 0 = browser bar, 1 = switcher bar. Driven by the switcher's animation.
    @State private var barMix: Double = 0
    @State private var doneTrigger = 0
    #if DEBUG
    @State private var debugStatsHome = CGRect.zero
    #endif
    @State private var switcherReloadTrigger = 0
    @State private var isShowingSettings = false
    @State private var isShowingHistory = false
    /// Tabs were added while History was open; the switcher catches up when it closes.
    @State private var switcherNeedsReload = false
    /// What's typed into a page's text prompt.
    @State private var dialogText = ""
    @State private var siteMenu: SiteMenuTarget?
    private let settings = AppSettings.shared
    /// Height of the "Incognito" strip under the status bar.
    private static let incognitoBarHeight: CGFloat = 16
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store = BrowserStore()
        _store = State(initialValue: store)
        _isSearching = State(initialValue: store.selectedTab?.isBlank ?? true)
        _searchIsIncognito = State(initialValue: store.selectedTab?.isIncognito ?? false)
    }

    var body: some View {
        ZStack {
            page
                // The keyboard must not push the page or bar around.
                .ignoresSafeArea(.keyboard)

            if isSwitching {
                TabSwitcher(
                    store: store,
                    barHeight: barHeight,
                    barMix: $barMix,
                    doneTrigger: doneTrigger,
                    reloadTrigger: switcherReloadTrigger,
                    onSelect: { tab in
                        store.select(tab)
                        closeSwitcher()
                    },
                    onClose: closeTab,
                    onDone: closeSwitcher,
                    onLeaveStart: { isExitingSwitcher = true }
                )
                .ignoresSafeArea(.keyboard)
                .id(switcherID)
                // It animates its own entrance, so appear instantly; on the
                // way out, cross-fade from the card to the live page.
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }

            bars
                // Same rule as the page: the keyboard doesn't push the bar up.
                .ignoresSafeArea(.keyboard)
                #if DEBUG
                .onPreferenceChange(DebugStatsHomeKey.self) { debugStatsHome = $0 }
                #endif

            #if DEBUG
            DebugStatsTracker(home: debugStatsHome, mix: barMix)
            #endif

            if let tab = store.selectedTab, let peek = tab.peek, !isSwitching {
                LinkPreview(
                    url: peek.url,
                    previewTab: peek.tab,
                    bottomInset: barHeight,
                    animateEntrance: !tab.peekWasPresented,
                    onPresented: tab.markPeekPresented,
                    onOpenNewTab: {
                        if let page = tab.takePeek() {
                            if page.searchText.isEmpty { page.searchText = tab.searchText }
                            store.adoptPreview(page, inBackground: false)
                        }
                    },
                    onOpenBackground: {
                        if let page = tab.takePeek() {
                            if page.searchText.isEmpty { page.searchText = tab.searchText }
                            store.adoptPreview(page, inBackground: true)
                        }
                    },
                    onOpen: { url in
                        tab.dismissPeek()
                        tab.load(url)
                    },
                    onDismiss: tab.dismissPeek
                )
                .id(peek.tab.id)
            }

            // Always in the view tree, just invisible when closed. A text
            // field that already exists can take the keyboard instantly;
            // one that has to be built first adds a noticeable delay.
            SearchOverlay(
                isPresented: isSearching,
                initialText: searchInitialText,
                selectInitialText: editingURL == nil,
                showsIncognitoToggle: editingURL == nil,
                isIncognito: $searchIsIncognito,
                onAppend: {
                    replaceGoogleSearchOnSubmit = searchOpenedFromGoogle
                },
                onSubmit: { input in
                    let isIncognito = searchIsIncognito
                    let replacing = editingURL != nil || (replaceGoogleSearchOnSubmit
                        && store.selectedTab?.isIncognito == isIncognito)
                    closeSearch()
                    Task {
                        if replacing, let tab = store.selectedTab,
                           let url = Destination.url(for: input) {
                            tab.load(url, input: input)
                        } else {
                            await store.open(input, isIncognito: isIncognito)
                        }
                        closeSwitcher()
                    }
                },
                onDismiss: closeSearch
            )

            // Hides the screen in the iOS app switcher, but only when what was
            // last on screen is private.
            if scenePhase != .active, store.selectedTab?.isIncognito == true {
                Color(.systemBackground).ignoresSafeArea()
                Label("Bark", systemImage: "eye.slash.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.purple)
            }
        }
        // Save when leaving the app: iOS may close it without further notice.
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                ClipboardCache.shared.refresh()
                Translation.forgetChromeAvailability()
            } else {
                store.save()
                HistoryStore.shared.flush()
            }
        }
        .onChange(of: settings.hideShorts) {
            store.applyShortsSetting(settings.hideShorts)
        }
        .onChange(of: settings.blockRedditPrompt) {
            store.applyRedditPromptSetting(settings.blockRedditPrompt)
        }
        .onChange(of: settings.blockAds) { ContentBlocker.shared.settingsChanged() }
        .onChange(of: settings.blockTrackers) { ContentBlocker.shared.settingsChanged() }
        .sheet(item: $siteMenu) { target in
            SiteMenu(target: target)
        }
        .sheet(isPresented: $isShowingHistory, onDismiss: {
            if switcherNeedsReload {
                switcherNeedsReload = false
                switcherReloadTrigger += 1
            }
        }) {
            HistoryView(
                onOpen: { url in
                    isShowingHistory = false
                    Task {
                        await store.open(url.absoluteString)
                        closeSwitcher()
                    }
                },
                onOpenInBackground: { url in
                    store.openInBackground(url)
                    switcherNeedsReload = true
                },
                onAdoptPeek: { tab, inBackground in
                    store.adoptPreview(tab, inBackground: inBackground)
                    if inBackground {
                        switcherNeedsReload = true
                    } else {
                        isShowingHistory = false
                        closeSwitcher()
                    }
                },
                onOpenPeekHere: { url in
                    isShowingHistory = false
                    store.selectedTab?.load(url)
                    closeSwitcher()
                },
                onDone: { isShowingHistory = false }
            )
        }
        .alert(
            dialogTitle,
            isPresented: Binding(
                get: { dialogTab?.dialog != nil },
                set: { if !$0 { dialogTab?.answerDialog(.cancel) } }
            ),
            presenting: dialogTab?.dialog
        ) { dialog in
            dialogButtons(dialog)
        } message: { dialog in
            Text(dialog.message)
        }
        .onChange(of: dialogTab?.dialog?.id) {
            if case .prompt(let defaultText) = dialogTab?.dialog?.kind { dialogText = defaultText }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(settings: settings, onDone: { isShowingSettings = false })
        }
        // Every so often, unload tabs that have sat unused for a while.
        .task {
            ClipboardCache.shared.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                store.enforceMemoryPolicy()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            ClipboardCache.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            store.unloadBackgroundTabs()
        }
    }

    /// Every tab's web view, then error/start states. (The bars sit above.)
    private var page: some View {
        let isIncognito = store.selectedTab?.isIncognito == true
        return ZStack(alignment: .bottom) {
            // All tabs stay mounted; only the selected one is visible.
            ForEach(store.tabs.filter(\.isLoaded)) { tab in
                WebViewHost(
                    webView: tab.webView!,
                    isActive: tab.id == store.selectedTabID,
                    onPreviewLink: { url in
                        guard tab.id == store.selectedTabID else { return }
                        tab.openPeek(url)
                    },
                    onVisible: tab.finishRestoringIfVisible
                )
                // Sit between the status bar and the floating bar, so nothing
                // on the page (header buttons, the end of an inner scrolling
                // panel like comments) is hidden behind them.
                .padding(.bottom, barHeight)
            }

            if let tab = store.selectedTab {
                // A tab that was unloaded takes a moment to come back; show its
                // card picture meanwhile instead of a white page.
                if tab.isRestoring, let image = tab.snapshot {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                        .padding(.bottom, barHeight)
                        .allowsHitTesting(false)
                        // The card is already visible during the switcher exit.
                        // Show this same picture at full opacity on handoff.
                        .transition(.identity)
                }
                // Stop these above the bar so its buttons stay usable.
                if tab.isBlank {
                    StartView()
                        .padding(.bottom, barHeight)
                } else if let error = tab.loadError {
                    ErrorView(error: error, retry: tab.reload)
                        .padding(.bottom, barHeight)
                }

                if tab.isForeignLanguage, !isSwitching, let url = tab.url,
                   Translation.canOpenInChrome(url) {
                    Button { Translation.openInChrome(url) } label: {
                        Image(systemName: "translate")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Translate in Chrome")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 12)
                    .padding(.bottom, barHeight + 12)
                }
            }
        }
        // The page shrinks a little to leave room for the strip.
        .padding(.top, isIncognito ? Self.incognitoBarHeight : 0)
        .overlay(alignment: .top) {
            if isIncognito {
                Text("Incognito")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.incognitoBarHeight)
                    .background(Color(.systemBackground).ignoresSafeArea(edges: .top))
                    .allowsHitTesting(false)
                    .accessibilityLabel("Incognito tab")
            }
        }
    }

    /// Both bottom bars, stacked above the page and the switcher, fading
    /// into one another as the switcher opens and closes.
    private var bars: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if let tab = store.selectedTab {
                    BottomBar(
                        tab: tab,
                        tabCount: store.tabs.count,
                        plusButtonWidth: geometry.size.width * 0.19,
                        onNewTab: { openSearch() },
                        onEditAddress: { openSearch(editing: store.selectedTab?.url) },
                        onSiteMenu: {
                            // Only web pages have a site to configure.
                            guard let site = ContentBlocker.site(for: tab.url) else { return }
                            siteMenu = SiteMenuTarget(tab: tab, site: site)
                        },
                        onShowTabs: openSwitcher,
                        onVoiceSearch: { url in
                            Task {
                                await store.open(url.absoluteString)
                                closeSwitcher()
                            }
                        }
                    )
                    // Put the address strip just above the physical bottom edge.
                    .padding(.bottom, -max(0, geometry.safeAreaInsets.bottom - 3))
                    // Report the bar's height so the page can make room.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
                    .opacity(1 - barMix)
                    .allowsHitTesting(!isSwitching || isExitingSwitcher)
                }

                if isSwitching {
                    SwitcherBar(
                        height: barHeight,
                        plusButtonWidth: geometry.size.width * 0.19,
                        canCloseAll: store.tabs.contains { !$0.isBlank || $0.isIncognito },
                        closedCount: store.closedTabCount,
                        onDone: { doneTrigger += 1 },
                        onNewTab: { openSearch() },
                        onCloseAll: {
                            store.closeAll()
                            switcherReloadTrigger += 1
                        },
                        onRestore: {
                            store.restoreClosed()
                            switcherReloadTrigger += 1
                        },
                        onHistory: { isShowingHistory = true },
                        onSettings: { isShowingSettings = true }
                    )
                    // `barHeight` was measured after the browser bar's negative
                    // bottom padding, so this lands the button row exactly
                    // where the browser bar's is. No padding of its own.
                    .opacity(barMix)
                    .allowsHitTesting(barMix > 0.5)
                }
            }
            // Anchor both bars to the bottom of the available screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    // MARK: - Page dialogs

    /// The tab whose page is waiting on a dialog: the held link's page if it
    /// asked, else the current page.
    private var dialogTab: Tab? {
        guard let tab = store.selectedTab else { return nil }
        if let peekTab = tab.peek?.tab, peekTab.dialog != nil { return peekTab }
        return tab
    }

    private var dialogTitle: String {
        guard let dialog = dialogTab?.dialog else { return "" }
        return dialog.site.map { "\($0) says" } ?? "This page says"
    }

    @ViewBuilder
    private func dialogButtons(_ dialog: PageDialog) -> some View {
        switch dialog.kind {
        case .alert:
            Button("OK") { dialogTab?.answerDialog(.ok(text: nil)) }
        case .confirm:
            Button("Cancel", role: .cancel) { dialogTab?.answerDialog(.cancel) }
            Button("OK") { dialogTab?.answerDialog(.ok(text: nil)) }
        case .prompt:
            TextField("", text: $dialogText)
            Button("Cancel", role: .cancel) { dialogTab?.answerDialog(.cancel) }
            Button("OK") { dialogTab?.answerDialog(.ok(text: dialogText)) }
        }
        if let site = dialog.site, dialogTab?.isIncognito != true {
            Button("Block Dialogs from This Site", role: .destructive) {
                PageDialogPermissions.shared.setAllowed(false, on: site)
                dialogTab?.answerDialog(.cancel)
            }
        }
    }

    // MARK: - Actions

    /// New tabs start with the previous search or entry selected.
    private func openSearch(editing url: URL? = nil) {
        editingURL = url
        searchIsIncognito = store.selectedTab?.isIncognito ?? false
        searchOpenedFromGoogle = url == nil
            && Destination.searchQuery(from: store.selectedTab?.url) != nil
        replaceGoogleSearchOnSubmit = false
        searchInitialText = url?.absoluteString
            ?? store.selectedTab?.searchText
            ?? ""
        withAnimation(.easeOut(duration: 0.2)) { isSearching = true }
    }

    private func closeSearch() {
        replaceGoogleSearchOnSubmit = false
        withAnimation(.easeOut(duration: 0.2)) { isSearching = false }
    }

    private func openSwitcher() {
        // Tapped while the switcher is flying away: reopen once it's gone.
        if isExitingSwitcher {
            reopenAfterExit = true
            return
        }
        // Ignore taps while one is already on its way (or open).
        guard !isPreparingSwitcher, !isSwitching else { return }
        isPreparingSwitcher = true
        Task {
            // Only wait for a picture when there is none at all. Otherwise the
            // one we have (refreshed after every scroll or load) is shown now,
            // and a newer one swaps in if it's still being taken.
            if let tab = store.selectedTab, tab.needsSnapshot {
                if !tab.hasSnapshot {
                    await tab.captureSnapshot()
                } else {
                    Task { await tab.captureSnapshot() }
                }
            }
            if let peekTab = store.selectedTab?.peek?.tab, peekTab.needsSnapshot {
                if !peekTab.hasSnapshot {
                    await peekTab.captureSnapshot()
                } else {
                    Task { await peekTab.captureSnapshot() }
                }
            }
            // The deck opens on the most recent tabs; have their thumbnails
            // ready so their cards don't arrive empty.
            let opening = store.tabsByRecency.suffix(TabSwitcher.cardsBehind + 2)
            await CardThumbnails.shared.prefetch(opening + opening.compactMap(\.peek?.tab))
            switcherID = UUID()
            isSwitching = true
            isPreparingSwitcher = false
        }
    }

    private func closeSwitcher() {
        withAnimation(.easeOut(duration: 0.15)) {
            isSwitching = false
            barMix = 0
        }
        isExitingSwitcher = false
        if reopenAfterExit {
            reopenAfterExit = false
            openSwitcher()
        }
    }

    private func closeTab(_ tab: Tab) {
        // The switcher owns the close/reflow animation for both its local
        // card list and the store; avoid a second, longer nested spring.
        let replacedWithBlank = store.close(tab)
        // Closed the very last tab: go back to the "start fresh" state.
        if replacedWithBlank {
            closeSwitcher()
            openSearch()
        }
    }
}

#Preview {
    BrowserView()
}
