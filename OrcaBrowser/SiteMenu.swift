import SwiftUI

/// What the site menu is about: a tab, and the site it was showing when the
/// menu opened (the menu keeps describing that site if the tab moves on).
struct SiteMenuTarget: Identifiable {
    let tab: Tab
    let site: String
    var id: UUID { tab.id }
}

/// Opens when you hold the address bar. Shows what was blocked on this page
/// and lets you switch ad and tracker blocking off for the whole site.
struct SiteMenu: View {
    let target: SiteMenuTarget
    /// In the incognito window, handing the page to Chrome is asked about first.
    var confirmsOpeningChrome = false
    private let settings = AppSettings.shared
    @State private var blocksAds: Bool
    @State private var blocksTrackers: Bool
    @State private var allowsDialogs: Bool
    @State private var isConfirmingChrome = false

    init(target: SiteMenuTarget, confirmsOpeningChrome: Bool = false) {
        self.target = target
        self.confirmsOpeningChrome = confirmsOpeningChrome
        let rules = target.tab.privateRules
        _blocksAds = State(initialValue: ContentBlocker.shared.isBlocking(.ads, on: target.site, privateRules: rules))
        _blocksTrackers = State(initialValue: ContentBlocker.shared.isBlocking(.trackers, on: target.site, privateRules: rules))
        _allowsDialogs = State(initialValue: rules?.allowsDialogs(on: target.site)
            ?? PageDialogPermissions.shared.allows(target.site))
    }

    private var isYouTube: Bool { target.site == "youtube.com" }

    private var adsActive: Bool { settings.blockAds && blocksAds }
    private var trackersActive: Bool { settings.blockTrackers && blocksTrackers }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.site)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(target.tab.isIncognito ? "Applies to this site in every incognito tab and is forgotten when the last one leaves it" : "Applies to every page on this site")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                CountTile(title: "Ads blocked", count: target.tab.adsBlocked, isActive: adsActive)
                CountTile(title: "Trackers blocked", count: target.tab.trackersBlocked, isActive: trackersActive)
            }

            VStack(spacing: 0) {
                Toggle("Block ads", isOn: $blocksAds)
                    .disabled(!settings.blockAds)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                Divider().padding(.leading, 16)
                Toggle("Block trackers", isOn: $blocksTrackers)
                    .disabled(!settings.blockTrackers)
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
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: blocksAds) { change(.ads, to: blocksAds) }
        .onChange(of: blocksTrackers) { change(.trackers, to: blocksTrackers) }
        .onChange(of: allowsDialogs) {
            if let rules = target.tab.privateRules {
                rules.setAllowsDialogs(allowsDialogs, on: target.site)
            } else {
                PageDialogPermissions.shared.setAllowed(allowsDialogs, on: target.site)
            }
        }
        .presentationDetents(isYouTube ? [.large] : [.height(540)])
        .presentationDragIndicator(.visible)
    }

    /// Remembers the choice for the site, then reloads so the page is
    /// fetched again under the new rules.
    private func change(_ category: ContentBlocker.Category, to enabled: Bool) {
        if let rules = target.tab.privateRules {
            ContentBlocker.shared.setBlocking(enabled, category, on: target.site, privateRules: rules)
        } else {
            ContentBlocker.shared.setBlocking(enabled, category, on: target.site)
        }
        target.tab.reload()
    }

    private var footnote: String {
        switch (settings.blockAds, settings.blockTrackers) {
        case (false, false): "Ad and tracker blocking are off for every site in Settings."
        case (false, true): "Ad blocking is off for every site in Settings."
        case (true, false): "Tracker blocking is off for every site in Settings."
        case (true, true): "Counts are for this page. Changing a switch reloads the page."
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
