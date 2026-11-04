import SwiftUI

/// What the site menu is about: a tab, and the site it was showing when the
/// menu opened (the menu keeps describing that site if the tab moves on).
struct SiteMenuTarget: Identifiable {
    let tab: Tab
    let site: String
    var id: UUID { tab.id }
}

/// Opens when you hold the address bar. Shows what was blocked on this page
/// and lets you switch ad, tracker and cookie banner blocking off for the whole site.
struct SiteMenu: View {
    let target: SiteMenuTarget
    /// In the incognito window, handing the page to Chrome is asked about first.
    var confirmsOpeningChrome = false
    private let settings = AppSettings.shared
    @State private var blocksAds: Bool
    @State private var blocksTrackers: Bool
    @State private var blocksBanners: Bool
    @State private var allowsDialogs: Bool
    @State private var isConfirmingChrome = false

    init(target: SiteMenuTarget, confirmsOpeningChrome: Bool = false) {
        self.target = target
        self.confirmsOpeningChrome = confirmsOpeningChrome
        let rules = target.tab.privateRules
        _blocksAds = State(initialValue: ContentBlocker.shared.isBlocking(.ads, on: target.site, privateRules: rules))
        _blocksTrackers = State(initialValue: ContentBlocker.shared.isBlocking(.trackers, on: target.site, privateRules: rules))
        _blocksBanners = State(initialValue: ContentBlocker.shared.isBlocking(.cookieBanners, on: target.site, privateRules: rules))
        _allowsDialogs = State(initialValue: rules?.allowsDialogs(on: target.site)
            ?? PageDialogPermissions.shared.allows(target.site))
    }

    private var isYouTube: Bool { target.site == "youtube.com" }

    private var adsActive: Bool { settings.blockAds && blocksAds }
    private var trackersActive: Bool { settings.blockTrackers && blocksTrackers }
    private var bannersActive: Bool { settings.blockCookieBanners && blocksBanners }

    var body: some View {
        // Scrolls when large text or a short screen leaves the sheet too small.
        ScrollView {
            content
        }
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: allowsDialogs) {
            if let rules = target.tab.privateRules {
                rules.setAllowsDialogs(allowsDialogs, on: target.site)
            } else {
                PageDialogPermissions.shared.setAllowed(allowsDialogs, on: target.site)
            }
        }
        .presentationDetents(isYouTube ? [.large] : [.height(600)])
        .presentationDragIndicator(.visible)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.site)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(target.tab.isIncognito ? "Applies to this site in every incognito tab and is forgotten when the last one leaves it" : "Applies to every page on this site")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: toggleAll) {
                    Image(systemName: "power")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(anyOn ? Color.accentColor : Color.secondary)
                        .frame(width: 40, height: 40)
                        .background(.thinMaterial, in: .circle)
                        .overlay {
                            if !anyOn {
                                Capsule()
                                    .fill(Color.secondary)
                                    .frame(width: 30, height: 2)
                                    .rotationEffect(.degrees(-45))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(anyOn ? "Turn off all blocking for this site" : "Turn on all blocking for this site")
            }

            HStack(spacing: 12) {
                CountTile(title: "Ads blocked", count: target.tab.adsBlocked, isActive: adsActive)
                CountTile(title: "Trackers blocked", count: target.tab.trackersBlocked, isActive: trackersActive)
                CountTile(title: "Banners blocked", count: target.tab.bannersBlocked, isActive: bannersActive)
            }

            VStack(spacing: 0) {
                Toggle("Block ads", isOn: binding($blocksAds, .ads))
                    .disabled(!settings.blockAds)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                Divider().padding(.leading, 16)
                Toggle("Block trackers", isOn: binding($blocksTrackers, .trackers))
                    .disabled(!settings.blockTrackers)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                Divider().padding(.leading, 16)
                Toggle("Hide cookie banners", isOn: binding($blocksBanners, .cookieBanners))
                    .disabled(!settings.blockCookieBanners && !settings.rejectConsent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
            }
            .background(.thinMaterial, in: .rect(cornerRadius: 14))

            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Allow dialogs", isOn: $allowsDialogs)
                .disabled(!settings.allowsPageDialogs)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(.thinMaterial, in: .rect(cornerRadius: 14))

            if !settings.allowsPageDialogs {
                Text("Page dialogs are off for every site in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if isYouTube {
                VStack(alignment: .leading, spacing: 8) {
                    Text("YouTube")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    VStack(spacing: 0) {
                        YouTubeToggles(settings: settings, separated: true)
                    }
                    .background(.thinMaterial, in: .rect(cornerRadius: 14))
                    Text("These are the same as the YouTube settings in Settings, and apply to every YouTube tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let url = target.tab.url, Translation.canOpenInChrome(url) {
                Button {
                    if confirmsOpeningChrome { isConfirmingChrome = true } else { Translation.openInChrome(url) }
                } label: {
                    Label("Open in Chrome", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.thinMaterial, in: .rect(cornerRadius: 14))
                        .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Chrome will get this page’s address, and it won’t be private there.",
                    isPresented: $isConfirmingChrome,
                    titleVisibility: .visible
                ) {
                    Button("Open in Chrome") { Translation.openInChrome(url) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    /// A switch that remembers its choice for the site and reloads.
    private func binding(_ state: Binding<Bool>, _ category: ContentBlocker.Category) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue },
            set: { enabled in
                state.wrappedValue = enabled
                remember(enabled, category)
                target.tab.reload()
            }
        )
    }

    private func remember(_ enabled: Bool, _ category: ContentBlocker.Category) {
        if let rules = target.tab.privateRules {
            ContentBlocker.shared.setBlocking(enabled, category, on: target.site, privateRules: rules)
        } else {
            ContentBlocker.shared.setBlocking(enabled, category, on: target.site)
        }
    }

    /// Any blocking running on this page, counting only what Settings leaves on.
    private var anyOn: Bool { adsActive || trackersActive || (blocksBanners && (settings.blockCookieBanners || settings.rejectConsent)) }

    /// The power button: everything off for the site, or back on if it
    /// already is. One reload for all three.
    private func toggleAll() {
        let enabled = !anyOn
        blocksAds = enabled
        blocksTrackers = enabled
        blocksBanners = enabled
        remember(enabled, .ads)
        remember(enabled, .trackers)
        remember(enabled, .cookieBanners)
        target.tab.reload()
    }

    private var footnote: String {
        var off: [String] = []
        if !settings.blockAds { off.append("Ad blocking") }
        if !settings.blockTrackers { off.append("tracker blocking") }
        if !settings.blockCookieBanners { off.append("cookie banner hiding") }
        switch off.count {
        case 0: return "Counts are for this page. Changing a switch reloads the page."
        case 3: return "Ad blocking, tracker blocking and cookie banner hiding are off for every site in Settings."
        case 2: return "\(off[0]) and \(off[1]) are off for every site in Settings."
        default: return "\(off[0]) is off for every site in Settings."
        }
    }
}

/// One big number with a caption. Dimmed, with "Off", when that kind of
/// blocking isn't running here.
private struct CountTile: View {
    let title: String
    let count: Int
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isActive ? "\(count)" : "Off")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: count)
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
        .opacity(isActive ? 1 : 0.5)
        .accessibilityElement(children: .combine)
    }
}
