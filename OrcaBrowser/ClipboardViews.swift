import SwiftUI

/// The little clipboard icon that sits just above the keyboard.
struct ClipboardButton: View {
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: isOpen ? "clipboard.fill" : "clipboard")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: .circle)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .contentShape(.circle)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Clipboard history")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

/// What is on the clipboard now, as a pill. Tapping does `action`.
struct ClipboardChip: View {
    let text: String
    let accessibilityText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.regularMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(accessibilityText): \(text)")
    }
}

/// Equal space on either side keeps the chip centered independently of the icon.
struct ClipboardControls: View {
    @Binding var isOpen: Bool
    let showsHistory: Bool
    let text: String
    let accessibilityText: String
    let action: () -> Void

    var body: some View {
        ZStack {
            if !text.isEmpty {
                ClipboardChip(text: text, accessibilityText: accessibilityText, action: action)
                    .clipboardHitRegion()
                    .padding(.horizontal, 52)
            }
            if showsHistory {
                HStack {
                    Spacer(minLength: 0)
                    ClipboardButton(isOpen: $isOpen)
                        .clipboardHitRegion()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40)
    }
}

/// The recent clipboard items, in a card above the keyboard. Tapping one
/// puts it in the field without taking the keyboard away; swiping one away
/// deletes it.
struct ClipboardPanel: View {
    let onSelect: (ClipboardItem) -> Void
    let onShowAll: () -> Void
    private let history = ClipboardHistory.shared

    /// Older items are one tap away in the full list.
    private static let visibleCount = 100

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Clipboard")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("See All", action: onShowAll)
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            Divider()
            if history.items.isEmpty {
                Text("Nothing copied yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(history.items.prefix(Self.visibleCount)) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            ClipboardRow(item: item)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .swipeActions {
                            Button(role: .destructive) {
                                history.delete(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(height: 260)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// One item: the start of its text, or a small picture, and when it was copied.
struct ClipboardRow: View {
    let item: ClipboardItem

    var body: some View {
        HStack(spacing: 12) {
            if item.kind == .image {
                ClipboardThumbnail(item: item)
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

struct ClipboardThumbnail: View {
    let item: ClipboardItem
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: item.id) {
            image = await ClipboardHistory.shared.thumbnail(for: item)
        }
        .accessibilityLabel("Image")
    }
}

/// The small chip that drops in from the top after an item is copied back,
/// or when it couldn't be typed into a field.
struct ClipboardNoticeChip: View {
    let notice: ClipboardNotice

    var body: some View {
        HStack(spacing: 8) {
            if let item = notice.item, item.kind == .image {
                ClipboardThumbnail(item: item)
                    .frame(width: 24, height: 24)
                    .clipShape(.rect(cornerRadius: 5))
            } else {
                Image(systemName: "clipboard")
            }
            Text(notice.title)
                .fontWeight(.medium)
            if let item = notice.item, item.kind == .text {
                Text(item.preview.replacing(/\s+/, with: " "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}

/// The icon and panel riding just above whatever keyboard is up, over a page
/// or a sheet (see `ClipboardOverlay`). The search field has its own, in
/// `SearchOverlay`.
struct ClipboardFloating: View {
    /// False while the search field is up or the setting is off.
    let isEnabled: Bool
    let onSelect: (ClipboardItem) -> Void
    /// Types what is on the clipboard now into the field.
    let onPasteClipboard: (String) -> Void
    let onShowAll: () -> Void

    private let clipboardCache = ClipboardCache.shared
    @State private var keyboardHeight: CGFloat = 0
    @State private var isOpen = false

    private var isShown: Bool { isEnabled && keyboardHeight > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isShown {
                if isOpen {
                    ClipboardPanel(
                        onSelect: { item in
                            isOpen = false
                            onSelect(item)
                        },
                        onShowAll: onShowAll
                    )
                    .clipboardHitRegion()
                    .transition(.opacity.combined(with: .offset(y: 12)))
                }
                ClipboardControls(
                    isOpen: $isOpen,
                    showsHistory: true,
                    text: clipboardCache.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    accessibilityText: "Paste copied text"
                ) {
                    isOpen = false
                    onPasteClipboard(clipboardCache.text)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, keyboardHeight + 8)
        // Measured from the bottom of the screen, which is where the
        // keyboard's frame is reported.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .ignoresSafeArea()
        .animation(.snappy(duration: 0.2), value: isOpen)
        .onChange(of: isShown) { if !isShown { isOpen = false } }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            else { return }
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = max(0, UIScreen.main.bounds.height - frame.minY)
            }
        }
    }
}

/// Everything in the history, with search, copy and delete.
struct ClipboardHistoryView: View {
    let onDone: () -> Void
    private let history = ClipboardHistory.shared
    @State private var searchText = ""
    @State private var copiedID: UUID?
    @State private var isConfirmingClear = false

    private var results: [ClipboardItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history.items }
        return history.items.filter { $0.kind == .text && $0.text.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "Nothing Copied Yet" : "No Results",
                        systemImage: searchText.isEmpty ? "clipboard" : "magnifyingglass",
                        description: Text(searchText.isEmpty
                            ? "Text and images you copy, or have copied when you open Orca, appear here."
                            : "Nothing in your clipboard history matches.")
                    )
                } else {
                    List {
                        ForEach(results) { item in
                            Button {
                                copy(item)
                            } label: {
                                HStack {
                                    ClipboardRow(item: item)
                                    if copiedID == item.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", role: .destructive) { history.delete(item) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search clipboard history")
            .navigationTitle("Clipboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
                if !history.items.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear", role: .destructive) { isConfirmingClear = true }
                    }
                }
            }
            .confirmationDialog("Clear clipboard history", isPresented: $isConfirmingClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { history.clear() }
            } message: {
                Text("This removes everything saved here. It can’t be undone.")
            }
        }
    }

    private func copy(_ item: ClipboardItem) {
        history.copyToPasteboard(item, announces: false)
        copiedID = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == item.id { copiedID = nil }
        }
    }
}
