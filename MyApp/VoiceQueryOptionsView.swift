import SwiftUI

struct VoiceQueryOptionsView: View {
    @Bindable var settings: AppSettings
    @State private var editing: VoiceQueryDestination?

    var body: some View {
        List {
            Section {
                Text("\(settings.voiceQueryOptions.active.count) of 9 enabled")
                    .font(.headline)
                Text("The first enabled option is the center and default. The remaining enabled options start at the left and go clockwise. Tap a name to edit; drag a handle to reorder.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("Layout preview") {
                VoiceQueryLayoutPreview(destinations: settings.voiceQueryOptions.active)
                    .frame(height: 320)
            }
            Section {
                ForEach(settings.voiceQueryOptions.order) { destination in
                    HStack(spacing: 12) {
                        Image(systemName: destination.symbol)
                            .foregroundStyle(destination.selectionColor)
                            .frame(width: 26)
                        Button {
                            editing = destination
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(destination.rawValue)
                                if let index = settings.voiceQueryOptions.active.firstIndex(of: destination) {
                                    Text(index == 0 ? "Center · default" : index == 1 ? "1 · Left" : "\(index) · Clockwise")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Toggle("Enable \(destination.rawValue)", isOn: Binding(
                            get: { settings.voiceQueryOptions.enabled.contains(destination) },
                            set: { settings.voiceQueryOptions.setEnabled(destination, $0) }
                        ))
                        .labelsHidden()
                        // Disable only the switch: the last enabled row can
                        // still be dragged to a different position.
                        .disabled((settings.voiceQueryOptions.active.count == 1 && settings.voiceQueryOptions.enabled.contains(destination)) || (settings.voiceQueryOptions.active.count == 9 && !settings.voiceQueryOptions.enabled.contains(destination)))
                    }
                }
                .onMove { source, target in
                    settings.voiceQueryOptions.move(from: source, to: target)
                }
            } header: {
                Text("Order and visibility")
            } footer: {
                Text("Keep one to nine options enabled. After the center/default, the preview follows the list from the left, clockwise. Disabled options keep their place. Changes are saved automatically.")
            }
            Section {
                Button("Add option", systemImage: "plus") {
                    editing = VoiceQueryDestination(rawValue: "", searchTemplate: "https://example.com/search?q={query}")
                }
            } footer: {
                Text("You can save more destinations and enable up to nine at a time.")
            }
        }
        .sheet(item: $editing) { destination in
            VoiceQueryDestinationEditor(destination: destination) { edited in
                settings.voiceQueryOptions.save(edited)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Voice search options")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct VoiceQueryLayoutPreview: View {
    let destinations: [VoiceQueryDestination]

    var body: some View {
        GeometryReader { geometry in
            let layout = VoiceQueryLayout(count: destinations.count, availableWidth: geometry.size.width)
            ZStack {
                ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
                    let size = index == 0 ? layout.centerSize : layout.outerSize
                    let offset = layout.offset(at: index)
                    VStack(spacing: 4) {
                        Image(systemName: destination.symbol)
                            .foregroundStyle(destination.selectionColor)
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
        .accessibilityLabel("\(destinations.count) destinations, with \(destinations[0].rawValue) in the center")
    }
}

private struct VoiceQueryDestinationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let destination: VoiceQueryDestination
    @State private var name = ""
    @State private var symbol = "globe"
    @State private var color = "blue"
    let onSave: (VoiceQueryDestination) -> Void
    @State private var template = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        VoiceQueryDestination.validTemplate(template)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Search URL", text: $template, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Destination")
                } footer: {
                    Text("Use {query} where the dictated words should go, for example https://www.google.com/search?q={query}. The query is encoded automatically.")
                }
                Section("Appearance") {
                    Picker("Icon", selection: $symbol) {
                        ForEach(VoiceQueryDestination.symbols, id: \.self) { symbol in
                            Label(symbol, systemImage: symbol).tag(symbol)
                        }
                    }
                    Picker("Highlight color", selection: $color) {
                        ForEach(VoiceQueryDestination.colors, id: \.self) { color in
                            Text(color.capitalized).tag(color)
                        }
                    }
                    Label(name.isEmpty ? "Preview" : name, systemImage: symbol)
                        .foregroundStyle(VoiceQueryDestination(rawValue: name, color: color).selectionColor)
                }
            }
            .navigationTitle(destination.rawValue.isEmpty ? "Add option" : "Edit option")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var saved = destination
                        saved.rawValue = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved.symbol = symbol
                        saved.color = color
                        // Retain the native built-in action when its URL was not changed.
                        if template != destination.editableTemplate { saved.searchTemplate = template }
                        onSave(saved)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                name = destination.rawValue
                symbol = destination.symbol
                color = destination.color
                template = destination.editableTemplate
            }
        }
        .environment(\.editMode, .constant(.inactive))
    }
}
