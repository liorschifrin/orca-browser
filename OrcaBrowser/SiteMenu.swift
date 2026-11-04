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
    private let settings = AppSettings.shared
    @State private var blocksAds: Bool
    @State private var blocksTrackers: Bool
    @State private var blocksBanners: Bool
    @State private var allowsDialogs: Bool

    init(target: SiteMenuTarget) {
        self.target = target
        _blocksAds = State(initialValue: ContentBlocker.shared.isBlocking(.ads, on: target.site))
        _blocksTrackers = State(initialValue: ContentBlocker.shared.isBlocking(.trackers, on: target.site))
        _blocksBanners = State(initialValue: ContentBlocker.shared.isBlocking(.cookieBanners, on: target.site))
        _allowsDialogs = State(initialValue: PageDialogPermissions.shared.allows(target.site))
    }

    private var adsActive: Bool { settings.blockAds && blocksAds }
    private var trackersActive: Bool { settings.blockTrackers && blocksTrackers }
    private var bannersActive: Bool { settings.blockCookieBanners && blocksBanners }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.site)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(target.tab.isIncognito ? "Site preferences cannot be saved in incognito." : "Applies to every page on this site")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                CountTile(title: "Ads blocked", count: target.tab.adsBlocked, isActive: adsActive)
                CountTile(title: "Trackers blocked", count: target.tab.trackersBlocked, isActive: trackersActive)
                CountTile(title: "Banners blocked", count: target.tab.bannersBlocked, isActive: bannersActive)
            }

            VStack(spacing: 0) {
                Toggle("Block ads", isOn: $blocksAds)
                    .disabled(!settings.blockAds || target.tab.isIncognito)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                Divider().padding(.leading, 16)
                Toggle("Block trackers", isOn: $blocksTrackers)
                    .disabled(!settings.blockTrackers || target.tab.isIncognito)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                Divider().padding(.leading, 16)
                Toggle("Hide cookie banners", isOn: $blocksBanners)
                    .disabled(!settings.blockCookieBanners || target.tab.isIncognito)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
            }
            .background(.thinMaterial, in: .rect(cornerRadius: 14))

            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("Allow dialogs", isOn: $allowsDialogs)
                .disabled(!settings.allowsPageDialogs || target.tab.isIncognito)
                .padding(.horizontal, 16)
                .frame(minHeight: 48)
                .background(.thinMaterial, in: .rect(cornerRadius: 14))

            if !settings.allowsPageDialogs {
                Text("Page dialogs are off for every site in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: blocksAds) { change(.ads, to: blocksAds) }
        .onChange(of: blocksTrackers) { change(.trackers, to: blocksTrackers) }
        .onChange(of: blocksBanners) { change(.cookieBanners, to: blocksBanners) }
        .onChange(of: allowsDialogs) {
            PageDialogPermissions.shared.setAllowed(allowsDialogs, on: target.site)
        }
        .presentationDetents([.height(540)])
        .presentationDragIndicator(.visible)
    }

    /// Remembers the choice for the site, then reloads so the page is
    /// fetched again under the new rules.
    private func change(_ category: ContentBlocker.Category, to enabled: Bool) {
        ContentBlocker.shared.setBlocking(enabled, category, on: target.site)
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
