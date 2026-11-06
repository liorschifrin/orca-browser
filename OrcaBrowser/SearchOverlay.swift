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
    /// The suggestion was held: the other sites that match are shown too.
    @State private var isShowingOtherSuggestions = false
    @State private var suggestionHoldTask: Task<Void, Never>?
    @State private var suggestionDidHold = false
    @State private var suggestionDidMove = false
    @State private var suggestionTouchStart = CGPoint.zero
    /// Everything is selected, the chip included: typing starts over without it.
    @State private var isChipSelected = false
    /// Where to put the cursor once the field has taken a programmatic edit.
    @State private var pendingCursorOffset: Int?
    @State private var hasEditedText = false
    @State private var isShowingClipboard = false
    @State private var selection: TextSelection?
    private let clipboardCache = ClipboardCache.shared
    private let settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

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
                if settings.savesClipboardHistory {
                    if isShowingClipboard {
                        ClipboardPanel(onSelect: insertFromHistory, onShowAll: ClipboardOverlay.shared.showAll)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }
                if isShowingOtherSuggestions, !otherSuggestions.isEmpty {
                    otherSuggestionsRow
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
                HStack(spacing: 0) {
                    if let provider = suggestedProvider { suggestionChip(provider) }
                    ClipboardControls(
                        isOpen: $isShowingClipboard,
                        showsHistory: settings.savesClipboardHistory,
                        text: clipboardText,
                        accessibilityText: shouldNavigateClipboard ? "Go to copied text" : "Paste copied text",
                        action: useClipboard
                    )
                }
                if clipboardCache.access == .needsPermission {
                    pastePermissionChip
                }
                field
            }
                .animation(.snappy(duration: 0.2), value: isShowingClipboard)
                .animation(.snappy(duration: 0.2), value: isShowingOtherSuggestions)
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
                clipboardCache.refresh(userInitiated: true)
            }
        }
        .onChange(of: isPresented) { _, nowPresented in
            if nowPresented {
                resetInput()
                isFocused = true
                clipboardCache.refresh(userInitiated: true)
            } else {
                isFocused = false
                isShowingClipboard = false
            }
        }
        // Back from Settings with search still open: pick up a changed choice.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isPresented { clipboardCache.refresh(userInitiated: true) }
        }
        .onChange(of: text) { _, newText in
            if newText != initialText { hasEditedText = true }
            // Typing on means the other matches are no longer what was held.
            if otherSuggestions.isEmpty { isShowingOtherSuggestions = false }
            if let offset = pendingCursorOffset {
                pendingCursorOffset = nil
                let shown = shownText
                selection = TextSelection(insertionPoint: Self.index(offset, in: shown))
            }
            guard shouldMatchShortcut else { return }
            shouldMatchShortcut = false
            // Let TextField finish its edit before replacing the shortcut with
            // a chip, so UIKit never inserts subsequent characters at a stale cursor.
            activateShortcutIfNeeded()
        }
        .onChange(of: isFocused) { _, focused in
            if focused, selectInitialText, !text.isEmpty || activeProvider != nil {
                // The chip is part of what's selected, so typing starts over without it.
                selectEverything()
                // The field takes its text in the same pass; once it has, select again.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    // SwiftUI can't place a selection in text with accented letters
                    // (its positions count bytes), so ask the field itself too.
                    if isFocused, isPresented, !hasEditedText {
                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                    }
                }
            } else if !focused {
                selection = nil
            }
        }
        .onChange(of: selection) { _, new in
            guard activeProvider != nil, let new, case .selection(let range) = new.indices else {
                isChipSelected = false
                return
            }
            let shown = shownText
            // The positions came from the field and may be for text that has since changed.
            guard range.lowerBound >= shown.startIndex, range.upperBound <= shown.endIndex else {
                isChipSelected = false
                return
            }
            isChipSelected = range.lowerBound.utf16Offset(in: shown) == 0
                && range.upperBound.utf16Offset(in: shown) == shown.utf16.count
        }
        .onChange(of: activeProvider?.id) { _, id in
            if id == nil { isChipSelected = false }
        }
    }

    /// Stands in for the chip inside the text field. It is invisible and has no
    /// width, but it is a real character (a plain ASCII one, because the field
    /// only places selections correctly in text where bytes and characters line up), so pressing delete with the cursor
    /// right after the chip removes it, and that is how we notice.
    private static let chipMarker = "\u{1}"

    private var shownText: String {
        activeProvider == nil ? text : Self.chipMarker + text
    }

    private func selectEverything() {
        let shown = shownText
        selection = TextSelection(range: Self.index(0, in: shown)..<Self.index(shown.utf16.count, in: shown))
    }

    /// Builds a cursor position in the text field's UTF-16 units; the ASCII
    /// chip marker occupies one unit, and queries can contain multibyte text.
    private static func index(_ offset: Int, in string: String) -> String.Index {
        String.Index(utf16Offset: min(max(0, offset), string.utf16.count), in: string)
    }

    /// Restores the remembered query and enabled provider without interpreting an ordinary query as a shortcut.
    private func resetInput() {
        suppressActivation = false
        shouldMatchShortcut = false
        pendingCursorOffset = nil
        hasEditedText = false
        isShowingOtherSuggestions = false
        isChipSelected = false
        activeProvider = settings.searchProviders.first { $0.id == initialProviderID && $0.isEnabled }
        typedShortcut = nil
        // Restoring a remembered ordinary query must not reinterpret it as a shortcut.
        text = initialText
    }

    /// Converts a complete shortcut plus whitespace into a chip, retaining the query and original token.
    private func activateShortcutIfNeeded() {
        guard activeProvider == nil, !suppressActivation,
              let match = SearchProvider.activation(for: text, in: settings.searchProviders) else { return }
        activeProvider = match.provider
        typedShortcut = String(text.drop(while: \.isWhitespace).prefix(while: { !$0.isWhitespace }))
        text = match.query
        pendingCursorOffset = text.utf16.count + 1
        selection = TextSelection(insertionPoint: Self.index(shownText.utf16.count, in: shownText))
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
        pendingCursorOffset = word.utf16.count
        selection = TextSelection(insertionPoint: Self.index(word.utf16.count, in: text))
    }

    private var suggestedProvider: SearchProvider? {
        guard activeProvider == nil else { return nil }
        return SearchProvider.bestSuggestion(for: text, in: settings.searchProviders)
    }

    private var clipboardText: String {
        clipboardCache.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every site the first word could mean, best first.
    private var allSuggestions: [SearchProvider] {
        guard activeProvider == nil else { return [] }
        return SearchProvider.suggestions(for: text, in: settings.searchProviders)
    }

    private var otherSuggestions: [SearchProvider] { Array(allSuggestions.dropFirst()) }

    /// Offers the site the first word could mean, at the left of the clipboard
    /// row. Tap to use it; hold to see the other sites that match.
    private func suggestionChip(_ provider: SearchProvider) -> some View {
        SearchProviderChip(provider: provider)
            // Raw touches, like the back button: SwiftUI's long press waits too long.
            .overlay {
                TouchSurface(
                    onBegan: { point in suggestionTouchBegan(at: point) },
                    onMoved: { point in
                        if hypot(point.x - suggestionTouchStart.x, point.y - suggestionTouchStart.y) > 14 {
                            suggestionDidMove = true
                            suggestionHoldTask?.cancel()
                        }
                    },
                    onEnded: { _ in
                        suggestionHoldTask?.cancel()
                        if !suggestionDidHold, !suggestionDidMove { selectProvider(provider) }
                    },
                    onCancelled: { suggestionHoldTask?.cancel() }
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Search \(provider.name)")
            .accessibilityHint("Turns the word you typed into this site's chip")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selectProvider(provider) }
            .accessibilityAction(named: "Show other sites") {
                if !otherSuggestions.isEmpty { isShowingOtherSuggestions.toggle() }
            }
            .accessibilityIdentifier("search-provider-suggestion")
    }

    /// Holding opens the other matches as quickly as holding the back button.
    private func suggestionTouchBegan(at point: CGPoint) {
        suggestionDidHold = false
        suggestionDidMove = false
        suggestionTouchStart = point
        suggestionHoldTask?.cancel()
        suggestionHoldTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, !otherSuggestions.isEmpty else { return }
            suggestionDidHold = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            isShowingOtherSuggestions = true
        }
    }

    private var otherSuggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(otherSuggestions) { provider in
                    SearchProviderChip(provider: provider)
                        .onTapGesture { selectProvider(provider) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Search \(provider.name)")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 0)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("search-provider-others")
    }

    /// Replaces the matched first token with a selected provider chip and focuses the remaining query.
    private func selectProvider(_ provider: SearchProvider) {
        // Replace the shortcut (or matched first word) with the inline chip.
        let trimmed = text.drop(while: \.isWhitespace)
        let end = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        typedShortcut = String(trimmed[..<end])
        text = String(trimmed[end...].drop(while: \.isWhitespace))
        activeProvider = provider
        isShowingOtherSuggestions = false
        suppressActivation = false
        isFocused = true
        pendingCursorOffset = text.utf16.count + 1
        selection = TextSelection(insertionPoint: Self.index(shownText.utf16.count, in: shownText))
    }

    private var shouldNavigateClipboard: Bool {
        Self.shouldNavigateClipboard(text: text, hasEditedText: hasEditedText)
    }

    static func shouldNavigateClipboard(text: String, hasEditedText: Bool) -> Bool {
        text.isEmpty || !hasEditedText
    }

    /// Opens clipboard text for an untouched entry, otherwise pastes it into the edited field.
    private func useClipboard() {
        isShowingClipboard = false
        if shouldNavigateClipboard {
            onSubmit(SearchSubmission(text: clipboardText))
        } else {
            ClipboardHistory.typeIntoField(clipboardCache.text)
        }
    }

    /// Shown whenever pasting has been refused or prompted, until a quick read
    /// shows "Paste from Other Apps" is set to Allow.
    private var pastePermissionChip: some View {
        Button(action: clipboardCache.openSettings) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                Text("Always allow paste in Settings")
                    .lineLimit(1)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.regularMaterial, in: .capsule)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint("Opens Settings so the clipboard can be read without asking each time")
    }

    private var field: some View {
        HStack(spacing: 8) {
            if let provider = activeProvider {
                // Part of the text: delete or its × turns it back into what was typed.
                Button { dissolveProvider(keeping: text) } label: {
                    SearchProviderChip(provider: provider, showsClose: true, isSelected: isChipSelected)
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                .accessibilityLabel("\(provider.name) search")
                .accessibilityHint("Turns it back into the text you typed")
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
        .animation(.snappy(duration: 0.18), value: activeProvider?.id)
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
                        if isChipSelected {
                            // Typed over a selection that included the chip: start over.
                            isChipSelected = false
                            activeProvider = nil
                            typedShortcut = nil
                            suppressActivation = false
                            text = newValue.replacingOccurrences(of: Self.chipMarker, with: "")
                            shouldMatchShortcut = true
                            return
                        }
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

    /// Submits the selected site query, opens its homepage for an empty query, or dismisses an empty entry.
    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // A chip with nothing after it opens that site's front page.
            if let provider = activeProvider, let home = SearchSubmission.home(of: provider) {
                onSubmit(home)
            } else {
                dismiss()
            }
        } else {
            guard let submission = SearchSubmission.make(text: text, provider: activeProvider) else { return }
            onSubmit(submission)
        }
    }

    /// Keeps the current entry open with one trailing space and activates a completed shortcut if present.
    private func appendToSearch() {
        onAppend()
        // Preserve the entry itself; normalize only its trailing whitespace.
        while text.last?.isWhitespace == true { text.removeLast() }
        if !text.isEmpty { text.append(" ") }
        activateShortcutIfNeeded()
        isFocused = true
        selection = TextSelection(insertionPoint: Self.index(shownText.utf16.count, in: shownText))
    }

    /// Types the item where the cursor is, without submitting, and puts it
    /// back on the clipboard at the top of the history.
    private func insertFromHistory(_ item: ClipboardItem) {
        isShowingClipboard = false
        ClipboardHistory.shared.insert(item)
    }

    private func dismiss() {
        isFocused = false
        onDismiss()
    }
}
