import SwiftUI

/// A small settings page, shown as a sheet from the switcher's gear button.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let onDone: () -> Void
    @State private var apiKey = ""
    @State private var hasAPIKey = VoiceSearchCredentials.apiKey != nil
    @State private var credentialError: String?
    @State private var isConfirmingClearHistory = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto-archive tabs", isOn: $settings.autoArchiveTabs)
                    Stepper(value: $settings.autoArchiveDays, in: 1...365) {
                        Text("After \(settings.autoArchiveDays) days")
                    }
                } header: {
                    Text("Tabs")
                } footer: {
                    Text("Archives tabs you haven’t opened for the selected number of days. Your current tab stays open. Find and reopen auto-archived tabs using the Archive button in the tab switcher.")
                }
                Section {
                    Toggle("Block ads", isOn: $settings.blockAds)
                    Toggle("Block trackers", isOn: $settings.blockTrackers)
                    Toggle("Hide cookie banners", isOn: $settings.blockCookieBanners)
                } header: {
                    Text("Blocking")
                } footer: {
                    Text("Uses AdGuard's filters, applied by the system rather than by scripts in the page. The lists update in the background every few days. Changes apply to pages you open next.")
                }
                Section {
                    Toggle("Block Reddit app pop-up", isOn: $settings.blockRedditPrompt)
                } footer: {
                    Text("Removes the \"Get the best of Reddit in the app\" pop-up that blocks the page on reddit.com.")
                }
                Section {
                    Toggle("Allow page dialogs", isOn: $settings.allowsPageDialogs)
                } footer: {
                    Text("Alerts, confirmations and prompts that pages show. When off, pages carry on as if you'd tapped Cancel. You can also switch them off for one site from its site menu.")
                }
                Section {
                    Toggle("Hide YouTube Shorts", isOn: $settings.hideShorts)
                } footer: {
                    Text("Hides Shorts shelves and cards on YouTube pages.")
                }
                Section {
                    Toggle("Open Shorts as regular videos", isOn: $settings.opensShortsAsVideos)
                } footer: {
                    Text("Tapping a Short, or opening a Shorts link, plays it in the normal YouTube player instead of the Shorts page.")
                }
                #if DEBUG
                Section("Debug") {
                    Toggle("Show FPS, memory and build", isOn: $settings.showDebugStats)
                }
                BlockingListsSection()
                #endif
                Section {
                    Button("Clear History…", role: .destructive) { isConfirmingClearHistory = true }
                } header: {
                    Text("History")
                }
                Section {
                    NavigationLink {
                        VoiceQueryOptionsView(settings: settings)
                    } label: {
                        HStack {
                            Text("Voice search options")
                            Spacer()
                            Text("\(settings.voiceQueryOptions.active.count) enabled")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Speech recognition", selection: $settings.voiceSearchProvider) {
                        ForEach(VoiceSearchProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    if settings.voiceSearchProvider == .openAI {
                        SecureField(hasAPIKey ? "Replace API key" : "OpenAI API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(saveAPIKey)
                        Button("Save API key", action: saveAPIKey)
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if hasAPIKey {
                            Label("API key saved in Keychain", systemImage: "checkmark.shield")
                            Button("Remove API key", role: .destructive) {
                                do {
                                    try VoiceSearchCredentials.remove()
                                    hasAPIKey = false
                                    apiKey = ""
                                } catch {
                                    credentialError = error.localizedDescription
                                }
                            }
                        }
                    }
                } header: {
                    Text("Voice search")
                } footer: {
                    Text(settings.voiceSearchProvider == .apple
                         ? "Swipe up from +, speak, then release to use your selected destination. Apple shows a live preview and finishes recognition before searching. Speech stays on device in your preferred iPhone language. A speech model may download on first use."
                         : "Recordings are sent to OpenAI only when you release the microphone. Uses gpt-transcribe and your own API billing. Your key stays in this device's Keychain. Local recordings are deleted after transcription or cancellation.")
                }
            }
            .confirmationDialog("Clear history", isPresented: $isConfirmingClearHistory, titleVisibility: .visible) {
                ClearHistoryButtons()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .alert("API key", isPresented: Binding(
                get: { credentialError != nil },
                set: { if !$0 { credentialError = nil } }
            )) {
                Button("OK", role: .cancel) { credentialError = nil }
            } message: {
                Text(credentialError ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func saveAPIKey() {
        do {
            try VoiceSearchCredentials.save(apiKey)
            hasAPIKey = true
            apiKey = ""
        } catch {
            credentialError = error.localizedDescription
        }
    }
}

#if DEBUG
/// What the blocking lists are doing, with a button to fetch them now instead
/// of waiting for the quiet moment the app normally picks.
private struct BlockingListsSection: View {
    private let status = ContentBlocker.shared.status

    var body: some View {
        Section {
            ForEach(status.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                    Text(detail(entry))
                        .font(.footnote)
                        .foregroundStyle(isFailed(entry) ? .red : .secondary)
                }
            }
            Button(status.isUpdating ? "Downloading…" : "Download lists now") {
                ContentBlocker.shared.updateNow()
            }
            .disabled(status.isUpdating)
        } header: {
            Text("Blocking lists")
        } footer: {
            if let checked = status.lastCheck {
                Text("Last full check \(checked.formatted(.relative(presentation: .named))).")
            } else {
                Text("Not checked yet. Lists download in the background once the app is quiet.")
            }
        }
    }

    private func isFailed(_ entry: ContentBlocker.Status.Entry) -> Bool {
        if case .failed = entry.phase { true } else { false }
    }

    private func detail(_ entry: ContentBlocker.Status.Entry) -> String {
        switch entry.phase {
        case .waiting: return "Waiting for a quiet moment…"
        case .downloading: return "Downloading…"
        case .converting: return "Converting…"
        case .compiling: return "Compiling…"
        case .failed(let reason): return "Failed: \(reason)"
        case .idle: break
        }
        guard entry.isLoaded else {
            return entry.updated == nil ? "Not downloaded" : "Downloaded, not loaded yet"
        }
        var parts = ["Active"]
        if let rules = entry.rules { parts.append("\(rules.formatted()) rules") }
        if let bytes = entry.bytes { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        if let updated = entry.updated { parts.append(updated.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }
}
#else
private struct BlockingListsSection: View {
    var body: some View { EmptyView() }
}
#endif
