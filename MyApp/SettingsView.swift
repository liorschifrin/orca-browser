import SwiftUI

/// A small settings page, shown as a sheet from the switcher's gear button.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Hide YouTube Shorts", isOn: $settings.hideShorts)
                } footer: {
                    Text("Hides Shorts on YouTube pages. Shorts links open as regular videos.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
