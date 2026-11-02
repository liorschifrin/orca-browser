import SwiftUI
import SwiftData

/// The list of visited pages, shown as a sheet from the tab switcher.
struct HistoryView: View {
    /// Opens the page in a new tab and leaves the switcher.
    let onOpen: (URL) -> Void
    let onOpenInBackground: (URL) -> Void
    /// A peeked page was promoted to a real tab (in the background or not).
    let onAdoptPeek: (Tab, _ inBackground: Bool) -> Void
    /// A peeked page was opened in the current tab.
    let onOpenPeekHere: (URL) -> Void
    let onDone: () -> Void

    @State private var searchText = ""
    @State private var isEditing = false
    @State private var selection = Set<PersistentIdentifier>()
    @State private var peek: HistoryPeek?
    private let history = HistoryStore.shared

    var body: some View {
        ZStack {
            NavigationStack {
                HistoryList(
                    searchText: searchText,
                    isEditing: isEditing,
                    selection: $selection,
                    onOpen: onOpen,
                    onOpenInBackground: onOpenInBackground,
                    onPeek: { peek = HistoryPeek(url: $0) }
                )
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                // On iPhone the system floats this at the bottom, as a capsule.
                .searchable(text: $searchText, prompt: "Search")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if isEditing {
                            if selection.isEmpty {
                                Menu("Clear…") {
                                    ClearHistoryButtons(undoable: true)
                                }
                            } else {
                                Button("Delete (\(selection.count))", role: .destructive) {
                                    history.hide(ids: selection)
                                    stopEditing()
                                }
                            }
                        } else {
                            Button("Edit") { setEditing(true) }
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        if isEditing {
                            Button("Cancel") { stopEditing() }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm, action: onDone)
                            .accessibilityLabel("Done")
                    }
                }
            }

            if !history.hiddenIDs.isEmpty {
                undoBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let peek {
                LinkPreview(
                    url: peek.url,
                    previewTab: peek.tab,
                    bottomInset: 0,
                    animateEntrance: true,
                    onPresented: {},
                    onOpenNewTab: { finishPeek { onAdoptPeek(peek.tab, false) } },
                    onOpenBackground: { finishPeek { onAdoptPeek(peek.tab, true) } },
                    onOpen: { url in
                        peek.tab.teardown()
                        self.peek = nil
                        onOpenPeekHere(url)
                    },
                    onDismiss: {
                        peek.tab.teardown()
                        self.peek = nil
                    }
                )
                .id(peek.tab.id)
            }
        }
        .modelContainer(HistoryStore.shared.container)
        // The list stays exactly as it was opened: pages visited meanwhile
        // (a background tab, a peek) are added once History closes.
        .onAppear { HistoryStore.shared.holdNewVisits() }
        .onDisappear { HistoryStore.shared.releaseNewVisits() }
        // Always full height, never the half-way stop.
        .presentationDetents([.large])
    }

    /// Offered after anything is removed, until it's carried out for good.
    private var undoBar: some View {
        let count = history.hiddenIDs.count
        return VStack {
            Spacer()
            HStack(spacing: 14) {
                Text(count == 1 ? "1 page removed" : "\(count) pages removed")
                    .font(.subheadline)
                Button("Undo") {
                    withAnimation(.smooth(duration: 0.3)) { history.undo() }
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            .glassEffect(.regular, in: .capsule)
            // Above the search field the system floats at the bottom.
            .padding(.bottom, 84)
        }
        .animation(.smooth(duration: 0.3), value: count)
    }

    /// The preview's page is kept alive; it now belongs to the browser.
    private func finishPeek(_ adopt: () -> Void) {
        adopt()
        peek = nil
    }

    private func setEditing(_ editing: Bool) {
        withAnimation(.smooth(duration: 0.3)) { isEditing = editing }
    }

    private func stopEditing() {
        selection = []
        setEditing(false)
    }
}

/// A page held in the history list, previewed the same way as a link.
private struct HistoryPeek {
    let url: URL
    let tab: Tab

    init(url: URL) {
        self.url = url
        tab = Tab()
    }
}

/// The three "clear" choices, shared by the history screen and Settings.
struct ClearHistoryButtons: View {
    /// In the history screen a clear can be undone for a few seconds; from
    /// Settings it happens at once.
    var undoable = false

    var body: some View {
        Button("Last hour", role: .destructive) {
            clear(since: .now.addingTimeInterval(-3600))
        }
        Button("Today", role: .destructive) {
            clear(since: Calendar.current.startOfDay(for: .now))
        }
        Button("All time", role: .destructive) {
            clear(since: nil)
        }
        if !undoable {
            Button("Cancel", role: .cancel) {}
        }
    }

    private func clear(since date: Date?) {
        if undoable {
            withAnimation(.smooth(duration: 0.3)) { HistoryStore.shared.hide(since: date) }
        } else {
            HistoryStore.shared.clear(since: date)
        }
    }
}

private struct HistoryList: View {
    let isEditing: Bool
    @Binding var selection: Set<PersistentIdentifier>
    let onOpen: (URL) -> Void
    let onOpenInBackground: (URL) -> Void
    let onPeek: (URL) -> Void
    @Query private var entries: [HistoryEntry]
    @Query private var icons: [HistoryIcon]
    private let isSearching: Bool

    init(searchText: String, isEditing: Bool, selection: Binding<Set<PersistentIdentifier>>,
         onOpen: @escaping (URL) -> Void, onOpenInBackground: @escaping (URL) -> Void,
         onPeek: @escaping (URL) -> Void) {
        self.isEditing = isEditing
        _selection = selection
        self.onOpen = onOpen
        self.onOpenInBackground = onOpenInBackground
        self.onPeek = onPeek
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = !query.isEmpty
        let predicate = #Predicate<HistoryEntry> {
            query.isEmpty
                || $0.title.localizedStandardContains(query)
                || $0.host.localizedStandardContains(query)
                || $0.urlString.localizedStandardContains(query)
        }
        _entries = Query(filter: predicate, sort: \.lastVisited, order: .reverse)
    }

    /// Newest first, grouped by calendar day.
    private var days: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleEntries) { calendar.startOfDay(for: $0.lastVisited) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    /// Without what was just deleted and can still be brought back.
    private var visibleEntries: [HistoryEntry] {
        let hidden = HistoryStore.shared.hiddenIDs
        return hidden.isEmpty ? entries : entries.filter { !hidden.contains($0.persistentModelID) }
    }

    private var iconsByHost: [String: UIImage] {
        Dictionary(icons.compactMap { icon in UIImage(data: icon.data).map { (icon.host, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        if visibleEntries.isEmpty {
            ContentUnavailableView(
                isSearching ? "No Results" : "No History",
                systemImage: isSearching ? "magnifyingglass" : "clock",
                description: Text(isSearching ? "Nothing in your history matches." : "Pages you visit will show up here.")
            )
        } else {
            let icons = iconsByHost
            List(selection: $selection) {
                ForEach(days, id: \.day) { section in
                    Section(Self.title(for: section.day)) {
                        ForEach(section.entries) { entry in
                            row(entry, icon: icons[entry.host])
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(isEditing ? .active : .inactive))
            .animation(.smooth(duration: 0.3), value: isEditing)
        }
    }

    private func row(_ entry: HistoryEntry, icon: UIImage?) -> some View {
        HStack(spacing: 12) {
            SiteIcon(image: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.host : entry.title)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    Text(entry.host)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(entry.lastVisited.formatted(date: .omitted, time: .shortened))
                        .monospacedDigit()
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        // The same row serves browsing and selecting, so it doesn't change
        // shape when the checkboxes slide in. While selecting, these are
        // switched off and the list handles taps and dragging itself.
        .gesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    guard let url = entry.url else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onPeek(url)
                }
                .exclusively(before: TapGesture().onEnded {
                    if let url = entry.url { onOpen(url) }
                }),
            including: isEditing ? .none : .all
        )
        .swipeActions(edge: .leading) {
            if let url = entry.url {
                Button {
                    onOpenInBackground(url)
                } label: {
                    Label("Open in Background", systemImage: "plus.square.on.square")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                withAnimation(.smooth(duration: 0.3)) { HistoryStore.shared.hide(entry) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

/// The site's icon in a rounded square, or a plain placeholder until it's known.
private struct SiteIcon: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(.rect(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
