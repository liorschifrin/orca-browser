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
                    Text("Archives tabs you haven’t opened for the selected number of days. Your current tab stays open. Use Restore closed tabs in the tab switcher to bring archived tabs back.")
                }
                Section {
                    Toggle("Block ads", isOn: $settings.blockAds)
                    Toggle("Block trackers", isOn: $settings.blockTrackers)
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
                    Text("Hides Shorts on YouTube pages. Shorts links open as regular videos.")
                }
                Section {
                    Button("Clear History…", role: .destructive) { isConfirmingClearHistory = true }
                } header: {
                    Text("History")
                }
                Section {
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
                         ? "Hold the microphone in the search bar, then release to search Google. Speech is processed on device in your preferred iPhone language. A speech model may download on first use."
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
