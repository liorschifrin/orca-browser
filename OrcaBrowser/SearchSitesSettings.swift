import SwiftUI

/// One place to manage every site you can search: which are typed with a
/// shortcut, which are on the voice layout, and how each looks in each place.
struct SearchSitesSettings: View {
    @Bindable var settings: AppSettings
    @State private var filter = Filter.all
    @State private var editing: SearchSite?
    @State private var message: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", typing = "Typing", voice = "Voice"
        var id: Self { self }
    }

    private var sites: [SearchSite] {
        switch filter {
        case .all: settings.searchSites.sites
        case .typing: settings.searchSites.sites.filter(\.usesTyping)
        case .voice: settings.searchSites.voiceSites
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(footer)
            }
            if filter == .voice {
                Section("Layout preview") {
                    VoiceLayoutPreview(destinations: settings.searchSites.voiceSites.map(\.voiceDestination))
                        .frame(height: 320)
                }
            }
            Section {
                ForEach(sites) { site in
                    row(site)
                }
                .onMove(perform: filter == .voice ? { source, target in
                    settings.searchSites.moveVoice(from: source, to: target)
                } : nil)
                .onDelete(perform: filter == .voice ? nil : { offsets in
                    for index in offsets { message = settings.searchSites.remove(sites[index].id) ?? message }
                })
            }
            Button("Add site", systemImage: "plus") {
                editing = SearchSite(name: "", template: "https://example.com/search?q=%s")
            }
        }
        .environment(\.editMode, .constant(filter == .voice ? .active : .inactive))
        .navigationTitle("Search sites")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { site in
            SearchSiteEditor(settings: settings, site: site)
        }
        .alert("Can’t do that", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .onAppear { SiteIconStore.shared.prefetch(hosts: settings.searchSites.sites.map(\.host)) }
    }

    private var footer: String {
        switch filter {
        case .all:
            "Type a shortcut and a space to search a site, or choose it from the voice layout. Tap a site to edit it; the keyboard and microphone buttons turn each use on or off."
        case .typing:
            "Type a shortcut and a space, or tap a suggestion. Press delete once to turn the chip back into text, or tap × to clear everything."
        case .voice:
            "\(settings.searchSites.voiceCount) of \(SearchSitePreferences.maxVoiceSites) on. The first is the center and default; the rest start at the left and go clockwise. Drag to reorder."
        }
    }

    private func row(_ site: SearchSite) -> some View {
        HStack(spacing: 12) {
            Button { editing = site } label: {
                HStack(spacing: 12) {
                    SiteIconView(icon: site.typingIcon, siteID: site.id, host: site.host,
                                 tint: SiteAppearance.color(siteID: site.id, host: site.host, setting: site.typingColor))
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.name).foregroundStyle(.primary)
                        Text(subtitle(site)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            useButton("keyboard", isOn: site.usesTyping, label: "Typing", site: site.name) {
                message = settings.searchSites.setUse(site.id, typing: !site.usesTyping)
            }
            useButton("mic", isOn: site.usesVoice, label: "Voice", site: site.name) {
                message = settings.searchSites.setUse(site.id, voice: !site.usesVoice)
            }
        }
    }

    private func subtitle(_ site: SearchSite) -> String {
        if filter == .voice, let index = settings.searchSites.voiceSites.firstIndex(where: { $0.id == site.id }) {
            return index == 0 ? "Center · default" : index == 1 ? "1 · Left" : "\(index) · Clockwise"
        }
        return site.shortcuts.isEmpty ? "No shortcut" : site.shortcuts.joined(separator: ", ")
    }

    private func useButton(_ symbol: String, isOn: Bool, label: String, site: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 34, height: 34)
                .background(isOn ? Color.accentColor.opacity(0.14) : Color.clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) search for \(site)")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct VoiceLayoutPreview: View {
    let destinations: [VoiceQueryDestination]

    var body: some View {
        GeometryReader { geometry in
            let layout = VoiceQueryLayout(count: destinations.count, availableWidth: geometry.size.width)
            ZStack {
                ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
                    let size = index == 0 ? layout.centerSize : layout.outerSize
                    let offset = layout.offset(at: index)
                    VStack(spacing: 4) {
                        VoiceDestinationIcon(destination: destination, tint: destination.selectionColor)
                        Text(index == 0 ? destination.rawValue : "\(index). \(destination.rawValue)")
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(width: size, height: size)
                    .background(destination.selectionColor.opacity(index == 0 ? 0.22 : 0.1), in: .rect(cornerRadius: layout.isCircular ? size / 2 : 24))
                    .position(x: geometry.size.width / 2 + offset.x, y: geometry.size.height / 2 + offset.y)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(destinations.count) destinations" + (destinations.first.map { ", with \($0.rawValue) in the center" } ?? ""))
    }
}

private enum SiteSymbols {
    static let all = [
        "magnifyingglass", "sparkles", "play.rectangle", "bubble.left.and.bubble.right", "cart", "map",
        "text.bubble", "book", "magnifyingglass.circle", "globe", "star", "music.note", "photo", "film",
        "newspaper", "bag", "house", "character.bubble", "person.2", "bolt",
    ]
}

private struct SearchSiteEditor: View {
    @Bindable var settings: AppSettings
    @State var site: SearchSite
    @State private var shortcuts = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { settings.searchSites.site(id: site.id) == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $site.name)
                    TextField("HTTPS search URL", text: $site.template, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Site")
                } footer: {
                    Text("Include exactly one %s where the query belongs. Edit the domain or URL parameters to change region or language.")
                }

                Section {
                    Toggle("Search by typing", isOn: $site.usesTyping)
                    TextField("Shortcuts, separated by commas", text: $shortcuts)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    IconPicker(selection: $site.typingIcon)
                    ColorChoice(selection: $site.typingColor, resolved: resolved(site.typingColor))
                    HStack {
                        Text("Preview").foregroundStyle(.secondary)
                        Spacer()
                        SearchProviderChip(provider: previewProvider, showsClose: true)
                    }
                } header: {
                    Text("Typing")
                }

                Section {
                    Toggle("Search by voice", isOn: $site.usesVoice)
                    IconPicker(selection: $site.voiceIcon)
                    ColorChoice(selection: $site.voiceColor, resolved: resolved(site.voiceColor))
                    HStack {
                        Text("Preview").foregroundStyle(.secondary)
                        Spacer()
                        VStack(spacing: 4) {
                            VoiceDestinationIcon(destination: site.voiceDestination, tint: resolved(site.voiceColor))
                            Text(site.name.isEmpty ? "Name" : site.name).font(.caption2).lineLimit(1)
                        }
                        .frame(width: 80, height: 64)
                        .background(resolved(site.voiceColor).opacity(0.18), in: .rect(cornerRadius: 18))
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text(site.opensChatGPTApp ? "Voice opens this in the ChatGPT app." : "The site’s icon is fetched from the site itself and kept on this phone.")
                }

                Section {
                    Button("Refresh site icon", systemImage: "arrow.clockwise") {
                        SiteIconStore.shared.refresh(host: site.host)
                    }
                    .disabled(site.host.isEmpty)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityLabel("Cannot save: \(error)") }
                }
                if !isNew {
                    Button("Remove site", role: .destructive) {
                        if let message = settings.searchSites.remove(site.id) { error = message } else { dismiss() }
                    }
                }
            }
            .navigationTitle(isNew ? "Add site" : "Edit site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear {
                shortcuts = site.shortcuts.joined(separator: ", ")
                SiteIconStore.shared.prefetch(hosts: [site.host])
            }
        }
    }

    private var previewProvider: SearchProvider {
        var candidate = site
        candidate.name = site.name.isEmpty ? "Name" : site.name
        return candidate.provider
    }

    private func resolved(_ color: SiteColor) -> Color {
        SiteAppearance.color(siteID: site.id, host: site.host, setting: color)
    }

    private func save() {
        site.shortcuts = shortcuts.components(separatedBy: ",")
        if let message = settings.searchSites.save(site) {
            error = message
        } else {
            SiteIconStore.shared.prefetch(hosts: [site.host])
            dismiss()
        }
    }
}

private struct IconPicker: View {
    @Binding var selection: SiteIconChoice

    var body: some View {
        Picker("Icon", selection: $selection) {
            Label("Site icon", systemImage: "photo.on.rectangle").tag(SiteIconChoice.site)
            ForEach(SiteSymbols.all, id: \.self) { name in
                Label(name, systemImage: name).tag(SiteIconChoice.symbol(name))
            }
        }
    }
}

private struct ColorChoice: View {
    @Binding var selection: SiteColor
    let resolved: Color

    var body: some View {
        Toggle("Use the site’s colour", isOn: Binding(
            get: { selection == .site },
            set: { selection = $0 ? .site : .custom(SiteColors.hex(of: resolved)) }
        ))
        if selection != .site {
            ColorPicker("Colour", selection: Binding(
                get: { resolved },
                set: { selection = .custom(SiteColors.hex(of: $0)) }
            ), supportsOpacity: false)
        }
    }
}
