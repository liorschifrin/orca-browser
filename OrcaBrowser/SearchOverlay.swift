import SwiftUI

/// The "type a search or address" sheet: a blurred backdrop with the text
/// field at the bottom, riding just above the keyboard (easy for one thumb).
///
/// This view stays in the hierarchy permanently and just fades in and out.
/// That keeps the text field "warm" so the keyboard can appear right away.
struct SearchOverlay: View {
    let isPresented: Bool
    /// Text the field starts with each time the overlay opens.
    var initialText = ""
    var selectInitialText = false
    /// The provider a remembered search was made with; its chip is shown on open.
    var initialProviderID: String?
    var showsIncognitoToggle = false
    /// Everything typed there is private already, so there's nothing to toggle.
    var isInIncognitoWindow = false
    @Binding var isIncognito: Bool
    let onAppend: () -> Void
    let onSubmit: (SearchSubmission) -> Void
    let onDismiss: () -> Void

    /// What's typed after the chip (or all of it when there is no chip).
    @State private var text = ""
    @State private var activeProvider: SearchProvider?
    /// The word that became the chip, put back when the chip turns into text.
    @State private var typedShortcut: String?
    // Turning a chip back into text must not immediately reactivate a query like “yt lofi”.
    @State private var suppressActivation = false
    @State private var shouldMatchShortcut = false
    /// Where to put the cursor once the field has taken a programmatic edit.
    @State private var pendingCursorOffset: Int?
    @State private var selection: TextSelection?
    private let settings = AppSettings.shared
    private let clipboardCache = ClipboardCache.shared
    @Environment(\.colorScheme) private var systemColorScheme

    /// @FocusState tracks (and controls) whether the field has the keyboard.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop: tapping anywhere outside the field dismisses.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
                    // Incognito darkens the whole screen, so it's obvious at a glance.
                    Color.black.opacity(isIncognito ? 0.55 : 0)
                }
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            if isIncognito {
                Text("You’re browsing Incognito")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 10) {
                suggestionRow
                field
            }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .offset(y: isPresented ? 0 : 24)
        }
        .environment(\.colorScheme, isIncognito ? .dark : systemColorScheme)
        .animation(.easeOut(duration: 0.2), value: isIncognito)
        .opacity(isPresented ? 1 : 0)
        // While invisible, it must not steal taps or show up for VoiceOver.
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        // Swiping down also dismisses.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 40 { dismiss() }
                }
        )
        .onAppear {
            // Presented at launch: grab the keyboard right away.
            if isPresented {
                resetInput()
                isFocused = true
                clipboardCache.refresh()
            }
        }
        .onChange(of: isPresented) { _, nowPresented in
            if nowPresented {
                resetInput()
                isFocused = true
                clipboardCache.refresh()
            } else {
                isFocused = false
            }
        }
        .onChange(of: text) { _, _ in
            if let offset = pendingCursorOffset {
                pendingCursorOffset = nil
                let shown = shownText
                selection = TextSelection(insertionPoint: shown.index(shown.startIndex, offsetBy: min(offset, shown.count)))
            }
            guard shouldMatchShortcut else { return }
            shouldMatchShortcut = false
            // Let TextField finish its edit before replacing the shortcut with
            // a chip, so UIKit never inserts subsequent characters at a stale cursor.
            activateShortcutIfNeeded()
        }
        .onChange(of: isFocused) { _, focused in
            if focused, selectInitialText, !text.isEmpty {
                // Keep the chip: typing over a remembered search replaces only its query.
                let shown = shownText
                let start = activeProvider == nil ? shown.startIndex : shown.index(after: shown.startIndex)
                selection = TextSelection(range: start..<shown.endIndex)
            } else if !focused {
                selection = nil
            }
        }
    }

    /// Stands in for the chip inside the text field. It is invisible and has no
    /// width, but it is a real character, so pressing delete with the cursor
    /// right after the chip removes it, and that is how we notice.
    private static let chipMarker = "\u{200B}"

    private var shownText: String {
        activeProvider == nil ? text : Self.chipMarker + text
    }

    private func resetInput() {
        suppressActivation = false
        shouldMatchShortcut = false
        pendingCursorOffset = nil
        activeProvider = settings.searchProviders.first { $0.id == initialProviderID && $0.isEnabled }
        typedShortcut = nil
        // Restoring a remembered ordinary query must not reinterpret it as a shortcut.
        text = initialText
    }

    private func activateShortcutIfNeeded() {
        guard activeProvider == nil, !suppressActivation,
              let match = SearchProvider.activation(for: text, in: settings.searchProviders) else { return }
        activeProvider = match.provider
        typedShortcut = SearchProvider.normalize(String(text.drop(while: \.isWhitespace).prefix(while: { !$0.isWhitespace })))
        text = match.query
        pendingCursorOffset = text.count + 1
        selection = TextSelection(insertionPoint: shownText.endIndex)
    }

    /// The chip turns back into the word it came from, and the cursor sits
    /// right after it, so one more delete edits the word like any other text.
    private func dissolveProvider(keeping query: String) {
        guard let provider = activeProvider else { return }
        let word = typedShortcut ?? provider.shortcuts.first ?? ""
        activeProvider = nil
        typedShortcut = nil
        shouldMatchShortcut = false
        suppressActivation = !query.isEmpty
        text = query.isEmpty ? word : word + " " + query
        pendingCursorOffset = word.count
        selection = TextSelection(insertionPoint: text.index(text.startIndex, offsetBy: word.count))
    }

    private var suggestedProvider: SearchProvider? {
        guard activeProvider == nil else { return nil }
        return SearchProvider.bestSuggestion(for: text, in: settings.searchProviders)
    }

    private var clipboardText: String {
        clipboardCache.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsClipboard: Bool { !clipboardText.isEmpty && clipboardText != text }

    @ViewBuilder
    private var suggestionRow: some View {
        if suggestedProvider != nil || showsClipboard {
            HStack(spacing: 8) {
                if let provider = suggestedProvider {
                    Button { selectProvider(provider) } label: {
                        SearchProviderChip(provider: provider)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search \(provider.name)")
                    .accessibilityHint("Selects this provider and keeps the query after the first word")
                    .accessibilityIdentifier("search-provider-suggestion")
                    .layoutPriority(1)
                }
                if showsClipboard {
                    clipboardChip
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func selectProvider(_ provider: SearchProvider) {
        // Replace the shortcut (or matched first word) with the inline chip.
        let trimmed = text.drop(while: \.isWhitespace)
        let end = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        typedShortcut = SearchProvider.normalize(String(trimmed[..<end]))
        text = String(trimmed[end...].drop(while: \.isWhitespace))
        activeProvider = provider
        suppressActivation = false
        isFocused = true
        pendingCursorOffset = text.count + 1
        selection = TextSelection(insertionPoint: shownText.endIndex)
    }

    /// Shows what was copied; tapping goes straight to it.
    private var clipboardChip: some View {
        Button {
            onSubmit(SearchSubmission(text: clipboardText))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                Text(clipboardText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.regularMaterial, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Go to copied text: \(clipboardText)")
    }

    private var field: some View {
        HStack(spacing: 8) {
            if let provider = activeProvider {
                // Part of the text: delete removes it, × clears it with the rest.
                SearchProviderChip(provider: provider)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("search-provider-active")
            } else {
                appendButton
            }

            queryField
                .frame(minWidth: 64)

            if !isInIncognitoWindow, showsIncognitoToggle || isIncognito {
                incognitoToggle
            }

            clearButton
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 52)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var appendButton: some View {
        Button(action: appendToSearch) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add to search")
        .accessibilityHint("Moves the cursor to the end with a space ready for more text")
    }

    private var queryField: some View {
        TextField(activeProvider.map { "Search \($0.name)" } ?? "Search or enter address", text: Binding(
            get: { shownText },
            set: { newValue in
                if activeProvider != nil {
                    guard newValue.hasPrefix(Self.chipMarker) else {
                        // The delete key reached the chip.
                        dissolveProvider(keeping: newValue.replacingOccurrences(of: Self.chipMarker, with: ""))
                        return
                    }
                    text = newValue.replacingOccurrences(of: Self.chipMarker, with: "")
                } else {
                    text = newValue
                }
                if text.isEmpty { suppressActivation = false }
                shouldMatchShortcut = true
            }
        ), selection: $selection)
            .focused($isFocused)
            .keyboardType(.webSearch)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(submit)
            .accessibilityIdentifier("search-query")
    }

    private var clearButton: some View {
        // Always laid out so the field's width doesn't change when it appears.
        let showsClear = !text.isEmpty || activeProvider != nil
        return Button {
            // Everything goes, the chip included.
            text = ""
            activeProvider = nil
            typedShortcut = nil
            suppressActivation = false
            shouldMatchShortcut = false
            isFocused = true
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(showsClear ? 1 : 0)
        .disabled(!showsClear)
        .accessibilityHidden(!showsClear)
        .accessibilityLabel("Clear")
    }

    /// Flips between normal and Incognito while the query is being typed;
    /// the field keeps its text and the keyboard stays up.
    private var incognitoToggle: some View {
        Button {
            isIncognito.toggle()
        } label: {
            HStack(spacing: 8) {
                if isIncognito {
                    Text("Incognito")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isIncognito ? "eye.slash.fill" : "eye.slash")
                    .font(.system(size: 18))
                    .foregroundStyle(isIncognito ? Color.primary : Color.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!showsIncognitoToggle)
        .accessibilityLabel("Incognito")
        .accessibilityValue(isIncognito ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dismiss()
        } else {
            guard let submission = SearchSubmission.make(text: text, provider: activeProvider) else { return }
            onSubmit(submission)
        }
    }

    private func appendToSearch() {
        onAppend()
        // Preserve the entry itself; normalize only its trailing whitespace.
        while text.last?.isWhitespace == true { text.removeLast() }
        if !text.isEmpty { text.append(" ") }
        activateShortcutIfNeeded()
        isFocused = true
        selection = TextSelection(insertionPoint: shownText.endIndex)
    }

    private func dismiss() {
        isFocused = false
        onDismiss()
    }
}
