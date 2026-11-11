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
    @State private var suggestionService = SearchSuggestionService()
    @State private var remoteSuggestions: [String] = []
    @State private var completedSuggestionRequest: SearchSuggestionRequest?
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
    /// Where the field's cursor goes next (once).
    @State private var selectionRequest: FieldSelectionRequest?
    @State private var hasEditedText = false
    @State private var isShowingClipboard = false
    /// A calculation, conversion or time answer for the typed text, if any.
    @State private var answer: SmartSearchAnswer.Answer?
    private let clipboardCache = ClipboardCache.shared
    private let settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    /// Whether the field has the keyboard; setting it gives or takes it.
    @State private var isFocused = false

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

            Group {
                switch settings.suggestionLook {
                case .panel: panelLayout
                case .floating: floatingLayout
                }
            }
                .animation(.snappy(duration: 0.2), value: isShowingClipboard)
                .animation(.snappy(duration: 0.2), value: answer)
                .animation(.snappy(duration: 0.2), value: isShowingOtherSuggestions)
                .animation(.snappy(duration: 0.2), value: settings.suggestionLook)
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
        .task(id: remoteSuggestionRequest) {
            let request = remoteSuggestionRequest
            remoteSuggestions = []
            completedSuggestionRequest = nil
            guard let request else {
                await suggestionService.clearCache()
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
                let values = try await suggestionService.suggestions(for: request)
                try Task.checkCancellation()
                guard remoteSuggestionRequest == request else { return }
                completedSuggestionRequest = request
                remoteSuggestions = values
            } catch {
                // Offline, cancelled, or changed endpoint: typing still works normally.
            }
        }
        .onAppear {
            // Presented at launch: grab the keyboard right away.
            if isPresented {
                resetInput()
                isFocused = true
                clipboardCache.refresh(userInitiated: true)
            }
            #if DEBUG
            if let typed = UserDefaults.standard.string(forKey: "debugSearchText") {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    text = typed
                    hasEditedText = true
                }
            }
            Task { await DebugKeys.replay() }
            #endif
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
            updateAnswer()
            // Typing on means the other matches are no longer what was held.
            if otherSuggestions.isEmpty { isShowingOtherSuggestions = false }
            guard shouldMatchShortcut else { return }
            shouldMatchShortcut = false
            // Let the field finish its edit before replacing the shortcut with
            // a chip, so UIKit never inserts subsequent characters at a stale cursor.
            activateShortcutIfNeeded()
        }
        .onChange(of: isFocused) { _, focused in
            if focused, selectInitialText, !text.isEmpty || activeProvider != nil {
                // The chip is part of what's selected, so typing starts over without it.
                selectionRequest = .all
            }
        }
        .task(id: isPresented && scenePhase == .active) {
            guard isPresented, scenePhase == .active else { return }
            while !Task.isCancelled {
                updateAnswer()
                let delay = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
        .onChange(of: activeProvider?.id) { _, _ in
            updateAnswer()
        }
    }

    private var showsRemoteSuggestions: Bool {
        !visibleRemoteSuggestions.isEmpty && !isShowingClipboard
    }

    /// What sits above every layout: clipboard history, other sites, the
    /// paste permission prompt and a calculation's answer.
    @ViewBuilder private var extras: some View {
        if settings.savesClipboardHistory, isShowingClipboard {
            ClipboardPanel(onSelect: insertFromHistory, onShowAll: ClipboardOverlay.shared.showAll)
                .transition(.opacity.combined(with: .offset(y: 12)))
        }
        if isShowingOtherSuggestions, !otherSuggestions.isEmpty {
            otherSuggestionsRow
                .transition(.opacity.combined(with: .offset(y: 8)))
        }
        if needsPastePermission {
            pastePermissionChip
        }
        if let answer {
            SmartAnswerCard(answer: answer, onReplace: replaceText)
                .transition(.opacity.combined(with: .offset(y: 12)))
        }
    }

    /// Suggestions, the clipboard and the field share one panel.
    private var panelLayout: some View {
        VStack(spacing: 10) {
            extras
            VStack(spacing: 0) {
                if showsRemoteSuggestions {
                    suggestionRows
                    Divider().padding(.horizontal, 16)
                }
                if suggestedProvider != nil || !clipboardText.isEmpty || settings.savesClipboardHistory {
                    HStack(spacing: 4) {
                        if let provider = suggestedProvider { suggestionChip(provider, height: 26) }
                        if clipboardText.isEmpty {
                            Spacer(minLength: 0)
                        } else {
                            ClipboardSuggestionRow(text: clipboardText, navigates: shouldNavigateClipboard, action: useClipboard)
                        }
                        if settings.savesClipboardHistory {
                            InlineClipboardButton(isOpen: $isShowingClipboard)
                        }
                    }
                    .padding(.leading, suggestedProvider == nil ? 22 : 12)
                    .padding(.trailing, 6)
                    Divider().padding(.horizontal, 16)
                }
                field(hasBackground: false)
            }
            .background(.regularMaterial, in: .rect(cornerRadius: 26))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }

    /// No card behind the suggestions; everything lines up with the field's text.
    private var floatingLayout: some View {
        VStack(spacing: 6) {
            extras
            if showsRemoteSuggestions {
                suggestionRows
            }
            floatingClipboardBar
            field(hasBackground: true)
                .padding(.top, 4)
        }
    }

    /// The clipboard chip sits centered, the same gap from the clipboard button
    /// as from the site chip (or, without one, from the edge).
    private var floatingClipboardBar: some View {
        let buttonWidth: CGFloat = settings.savesClipboardHistory ? 40 : 0
        return HStack(spacing: 0) {
            if let provider = suggestedProvider {
                suggestionChip(provider, height: 30)
            } else {
                Color.clear.frame(width: buttonWidth, height: 1)
            }
            if clipboardText.isEmpty {
                // Nothing copied: the site chip stays left, the button right.
                Spacer(minLength: 12)
            } else {
                ClipboardChip(
                    text: clipboardText,
                    accessibilityText: shouldNavigateClipboard ? "Go to copied text" : "Paste copied text",
                    action: useClipboard
                )
                .clipboardHitRegion()
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
            }
            if settings.savesClipboardHistory {
                ClipboardButton(isOpen: $isShowingClipboard)
                    .clipboardHitRegion()
            }
        }
        .frame(minHeight: 40)
    }

    /// One line each, best match nearest the field (the thumb). Never more
    /// than five, so no scrolling (which would also hide grey text on the blur).
    private var suggestionRows: some View {
        let suggestions = Array(visibleRemoteSuggestions.prefix(5).reversed())
        return VStack(spacing: 0) {
                ForEach(suggestions, id: \.self) { suggestion in
                    HStack(spacing: 0) {
                        Button {
                            searchSuggestion(suggestion)
                        } label: {
                            SuggestionRowLabel(suggestion: suggestion, typed: text)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Search for \(suggestion)")
                        Button {
                            editSuggestion(suggestion)
                        } label: {
                            Image(systemName: "arrow.up.left")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("Edit suggestion: \(suggestion)")
                    }
                    .padding(.leading, 22)
                    .padding(.trailing, 4)
                }
        }
        .padding(.vertical, 4)
        .buttonStyle(.plain)
        .accessibilityIdentifier("search-query-suggestions")
    }

    private func searchSuggestion(_ suggestion: String) {
        // Explicitly search: a completion must never become a URL.
        let url = activeProvider?.url(for: suggestion) ?? Destination.searchURL(for: suggestion)
        onSubmit(SearchSubmission(text: suggestion, url: url, providerID: activeProvider?.id))
    }

    private func editSuggestion(_ suggestion: String) {
        suppressActivation = true
        shouldMatchShortcut = false
        hasEditedText = true
        text = suggestion
        isFocused = true
        moveCaretToEnd()
    }

    private var remoteSuggestionRequest: SearchSuggestionRequest? {
        SearchSuggestionRequest.make(
            text: text, provider: activeProvider, enabled: settings.searchSuggestions,
            isPresented: isPresented && scenePhase == .active,
            isEditing: isFocused && hasEditedText,
            isIncognito: isIncognito || isInIncognitoWindow,
            inEnglish: settings.googleInEnglish
        )
    }

    private var visibleRemoteSuggestions: [String] {
        guard let request = remoteSuggestionRequest,
              request == completedSuggestionRequest else { return [] }
        return remoteSuggestions
    }

    /// The chip is one character in the field, before the text.
    private var shownLength: Int {
        text.utf16.count + (activeProvider == nil ? 0 : 1)
    }

    private func moveCaretToEnd() {
        selectionRequest = .caret(shownLength)
    }

    /// Restores the remembered query and enabled provider without interpreting an ordinary query as a shortcut.
    private func resetInput() {
        suppressActivation = false
        shouldMatchShortcut = false
        hasEditedText = false
        isShowingOtherSuggestions = false
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
        moveCaretToEnd()
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
        selectionRequest = .caret(word.utf16.count)
    }

    private var suggestedProvider: SearchProvider? {
        guard activeProvider == nil else { return nil }
        return SearchProvider.bestSuggestion(for: text, in: settings.searchProviders)
    }

    private var needsPastePermission: Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "debugClipboardText") != nil { return false }
        #endif
        return clipboardCache.access == .needsPermission
    }

    private var clipboardText: String {
        #if DEBUG
        // The simulator refuses pastes; screenshots can supply one.
        if let fake = UserDefaults.standard.string(forKey: "debugClipboardText") { return fake }
        #endif
        return clipboardCache.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every site the first word could mean, best first.
    private var allSuggestions: [SearchProvider] {
        guard activeProvider == nil else { return [] }
        return SearchProvider.suggestions(for: text, in: settings.searchProviders)
    }

    private var otherSuggestions: [SearchProvider] { Array(allSuggestions.dropFirst()) }

    /// Offers the site the first word could mean, at the left of the clipboard
    /// row. Tap to use it; hold to see the other sites that match.
    private func suggestionChip(_ provider: SearchProvider, height: CGFloat = 22) -> some View {
        SearchProviderChip(provider: provider, height: height)
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
        moveCaretToEnd()
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

    private func field(hasBackground: Bool) -> some View {
        HStack(spacing: 8) {
            appendButton

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
        // Inside the panel there is no layer of its own: even a clear one
        // would stop grey text drawing on the panel's blur.
        .background {
            if hasBackground {
                // A capsule at one line; long text wraps without stretching the ends.
                RoundedRectangle(cornerRadius: 26)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            }
        }
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

    private var chipImage: UIImage? {
        activeProvider.flatMap { ChipImages.image(for: $0, scale: displayScale) }
    }

    private var queryField: some View {
        ChipTextField(
            placeholder: activeProvider.map { "Search \($0.name)" } ?? "Search or enter address",
            text: $text,
            chip: chipImage,
            chipID: activeProvider?.id,
            chipWord: activeProvider.map { typedShortcut ?? $0.shortcuts.first ?? "" } ?? "",
            isFocused: $isFocused,
            selectionRequest: selectionRequest,
            onDeleteChip: { query in dissolveProvider(keeping: query) },
            onReplaceChip: { newText, caret in
                // Typed over a selection that included the chip: start over without it.
                activeProvider = nil
                typedShortcut = nil
                suppressActivation = false
                text = newText
                shouldMatchShortcut = true
                selectionRequest = .caret(caret)
            },
            onTapChip: { dissolveProvider(keeping: text) },
            onEdit: {
                if text.isEmpty { suppressActivation = false }
                shouldMatchShortcut = true
            },
            onSubmit: submit
        )
        // The field has no placeholder of its own; this one sits after the chip, if any.
        .overlay(alignment: .topLeading) {
            if text.isEmpty {
                Text(activeProvider.map { "Search \($0.name)" } ?? "Search or enter address")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, chipImage?.size.width ?? 0)
                    .padding(.top, ChipTextField.verticalInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
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
        moveCaretToEnd()
    }

    /// Searching inside a site (a chip is showing) is never a calculation.
    private func updateAnswer() {
        answer = activeProvider == nil
            ? SmartSearchAnswer.evaluate(text)
            : nil
    }

    /// Swaps what's typed for an answer, with the cursor after it.
    private func replaceText(with newText: String) {
        text = newText
        isFocused = true
        moveCaretToEnd()
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

/// The answer to a typed calculation, conversion or time question, shown just
/// above the field with a button to copy it.
private struct SmartAnswerCard: View {
    let answer: SmartSearchAnswer.Answer
    let onReplace: (String) -> Void
    @State private var didCopy = false
    /// Counts taps, so each one restarts the confirmation's timer.
    @State private var copyTaps = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "equal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(answer.result)
                    .font(.headline)
                    .textSelection(.enabled)
                Text(answer.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                onReplace(answer.fieldText)
            } label: {
                Image(systemName: "arrow.up.backward")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use result in search field")
            Button {
                ClipboardCache.shared.copy(text: answer.copyText)
                didCopy = true
                copyTaps += 1
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Copied" : "Copy result")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        // A new answer is a new thing to copy.
        .onChange(of: answer) { didCopy = false }
        // The checkmark only confirms the tap, so it fades back after a moment.
        .task(id: copyTaps) {
            guard copyTaps > 0 else { return }
            try? await Task.sleep(for: .seconds(1.2))
            // A newer tap cancels this task, and its own timer takes over.
            if !Task.isCancelled { didCopy = false }
        }
    }
}
