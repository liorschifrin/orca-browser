import SwiftUI

struct SearchProviderSettings: View {
    @Bindable var settings: AppSettings
    @State private var editing: SearchProvider?

    var body: some View {
        List {
            Section {
                ForEach(settings.searchProviders) { provider in
                    Button { editing = provider } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(provider.name).foregroundStyle(.primary)
                                Text(provider.shortcuts.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !provider.isEnabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let providers = settings.searchProviders
                    for index in offsets { settings.searchProviderPreferences.remove(providers[index]) }
                }
            } footer: {
                Text("Type a shortcut followed by a space, or tap a search provider suggestion. Tap × beside the active provider to return to regular search without clearing your query.")
            }
            Button("Add provider", systemImage: "plus") {
                editing = SearchProvider(name: "", shortcuts: [], template: "https://example.com/search?q=%s")
            }
        }
        .navigationTitle("Search providers")
        .sheet(item: $editing) { provider in
            SearchProviderEditor(settings: settings, provider: provider)
        }
    }
}

private struct SearchProviderEditor: View {
    @Bindable var settings: AppSettings
    @State var provider: SearchProvider
    @State private var shortcuts = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $provider.name)
                    TextField("Shortcuts, separated by commas", text: $shortcuts)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Enabled", isOn: $provider.isEnabled)
                }
                Section {
                    TextField("HTTPS search URL", text: $provider.template, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: { Text("Search URL template") } footer: {
                    Text("Include exactly one %s where the query belongs. Edit the domain or URL parameters here to change region or language. Maximum 2,048 bytes.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityLabel("Cannot save: \(error)") }
                }
                if settings.searchProviders.contains(where: { $0.id == provider.id }) {
                    Button("Remove provider", role: .destructive) {
                        settings.searchProviderPreferences.remove(provider)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Search provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save) }
            }
            .onAppear { shortcuts = provider.shortcuts.joined(separator: ", ") }
        }
    }

    private func save() {
        provider.shortcuts = shortcuts.components(separatedBy: ",")
        let candidate = provider.normalized()
        if let message = candidate.validationError(among: settings.searchProviders) {
            error = message
            return
        }
        settings.searchProviderPreferences.save(candidate)
        dismiss()
    }
}
