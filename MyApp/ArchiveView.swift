import SwiftUI

struct ArchiveView: View {
    let store: BrowserStore
    let onOpen: () -> Void
    let onDone: () -> Void

    @State private var searchText = ""
    @State private var errorMessage: String?

    private var days: [(day: Date, entries: [ArchivedTab])] {
        let grouped = Dictionary(grouping: store.archivedTabs.filter { $0.matches(searchText) }) {
            Calendar.current.startOfDay(for: $0.archivedAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            (day, (grouped[day] ?? []).sorted { $0.archivedAt > $1.archivedAt })
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No Archived Tabs" : "No Results",
                        systemImage: searchText.isEmpty ? "archivebox" : "magnifyingglass",
                        description: Text(searchText.isEmpty
                            ? "Tabs archived automatically after inactivity will appear here."
                            : "Nothing in your archive matches.")
                    )
                } else {
                    List {
                        ForEach(days, id: \.day) { section in
                            Section(title(for: section.day)) {
                                ForEach(section.entries) { entry in
                                    row(entry)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm, action: onDone)
                        .accessibilityLabel("Done")
                }
            }
            .alert("Archive", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents([.large])
    }

    private func row(_ entry: ArchivedTab) -> some View {
        Button {
            restore(entry, inBackground: false)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: .rect(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(entry.tab.url?.host() ?? entry.tab.url?.absoluteString ?? "")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(entry.archivedAt.formatted(date: .omitted, time: .shortened))
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button {
                restore(entry, inBackground: true)
            } label: {
                Label("Open in Background", systemImage: "plus.square.on.square")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                do {
                    try store.deleteArchived(entry)
                } catch {
                    errorMessage = error.localizedDescription
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button("Open Tab") { restore(entry, inBackground: false) }
            Button("Open in Background") { restore(entry, inBackground: true) }
        }
    }

    private func restore(_ entry: ArchivedTab, inBackground: Bool) {
        do {
            try store.restoreArchived(entry, inBackground: inBackground)
            if !inBackground { onOpen() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func title(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}
