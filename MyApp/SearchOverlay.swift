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
    var initialProviderID: String?
    let onAppend: () -> Void
    let onSubmit: (SearchSubmission) -> Void
    let onDismiss: () -> Void

    @State private var text = ""
    @State private var activeProvider: SearchProvider?
    // Exiting mode must not immediately reactivate a query like “a book”.
    @State private var suppressActivation = false
    @State private var shouldMatchShortcut = false
    @State private var selection: TextSelection?
    private let clipboardCache = ClipboardCache.shared
    @State private var voiceSearch = VoiceSearch()
    @Environment(\.scenePhase) private var scenePhase
    private let settings = AppSettings.shared

    /// @FocusState tracks (and controls) whether the field has the keyboard.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop: tapping anywhere outside the field dismisses.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(spacing: 10) {
                if let status = voiceSearch.status {
                    Text(status)
                        .font(.subheadline)
                        .padding(12)
                        .background(.regularMaterial, in: .capsule)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                suggestionRow
                field
            }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .offset(y: isPresented ? 0 : 24)
        }
        .opacity(isPresented ? 1 : 0)
        // While invisible, it must not steal taps or show up for VoiceOver.
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        // Swiping down also dismisses.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if !voiceSearch.isBusy, value.translation.height > 40 { dismiss() }
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
                voiceSearch.cancel()
                isFocused = false
            }
        }
        .onChange(of: text) { _, _ in
            guard shouldMatchShortcut else { return }
            shouldMatchShortcut = false
            // Let TextField finish its edit before replacing the shortcut with
            // a token, so UIKit never inserts subsequent characters at a stale cursor.
            activateShortcutIfNeeded()
        }
        .onChange(of: isFocused) { _, focused in
            if focused, selectInitialText, !text.isEmpty {
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            } else if !focused {
                selection = nil
            }
        }
        .cancelsVoiceSearchWhenInterrupted(voiceSearch)
        .alert("Voice search", isPresented: Binding(
            get: { voiceSearch.errorMessage != nil },
            set: { if !$0 { voiceSearch.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { voiceSearch.errorMessage = nil }
        } message: {
            Text(voiceSearch.errorMessage ?? "")
        }
    }

    private func resetInput() {
        suppressActivation = false
        shouldMatchShortcut = false
        activeProvider = settings.searchProviders.first { $0.id == initialProviderID && $0.isEnabled }
        // Restoring a remembered ordinary query must not reinterpret it as a shortcut.
        text = initialText
    }

    private func activateShortcutIfNeeded() {
        guard activeProvider == nil, !suppressActivation,
              let match = SearchProvider.activation(for: text, in: settings.searchProviders) else { return }
        activeProvider = match.provider
        text = match.query
        selection = TextSelection(insertionPoint: text.endIndex)
    }

    private var suggestedProvider: SearchProvider? {
        guard activeProvider == nil else { return nil }
        return SearchProvider.bestSuggestion(for: text, in: settings.searchProviders)
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
        text = String(trimmed[end...].drop(while: \.isWhitespace))
        activeProvider = provider
        suppressActivation = false
        isFocused = true
        selection = TextSelection(insertionPoint: text.endIndex)
    }

    private func leaveProvider() {
        activeProvider = nil
        suppressActivation = true
        isFocused = true
        selection = TextSelection(insertionPoint: text.endIndex)
    }

    private var clipboardText: String {
        clipboardCache.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
                Button(action: leaveProvider) {
                    SearchProviderChip(provider: provider, showsClose: true)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Leave \(provider.name) search and keep query")
                .accessibilityIdentifier("search-provider-active")
            } else {
                appendButton
            }

            queryField
                .frame(minWidth: 64)

            if voiceSearch.state == .transcribing || voiceSearch.state == .downloading {
                ProgressView()
                    .frame(width: 44, height: 44)
            } else {
                VoiceSearchButton(
                    isRecording: voiceSearch.state == .recording,
                    isEnabled: isPresented,
                    onPress: { voiceSearch.begin(provider: settings.voiceSearchProvider) },
                    onRelease: finishVoiceSearch,
                    onCancel: { voiceSearch.cancel() }
                )
                .frame(width: 44, height: 44)
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
            get: { text },
            set: {
                text = $0
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
        // Always laid out so the microphone doesn't shift when it appears.
        let showsClear = !text.isEmpty || voiceSearch.isBusy
        return Button {
            voiceSearch.cancel()
            text = ""
            suppressActivation = false
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
        .accessibilityLabel(voiceSearch.isBusy ? "Cancel voice search" : "Clear")
    }

    private func submit() {
        voiceSearch.cancel()
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
        selection = TextSelection(insertionPoint: text.endIndex)
    }

    private func dismiss() {
        voiceSearch.cancel()
        isFocused = false
        onDismiss()
    }

    private func finishVoiceSearch() {
        voiceSearch.finish { transcript in
            guard isPresented, scenePhase == .active else { return }
            let submission: SearchSubmission?
            if let activeProvider {
                submission = SearchSubmission.make(text: transcript, provider: activeProvider)
            } else if let url = Destination.searchURL(for: transcript) {
                submission = SearchSubmission(text: transcript, url: url)
            } else {
                submission = nil
            }
            guard let submission else { return }
            text = transcript
            isFocused = false
            onSubmit(submission)
        }
    }
}
