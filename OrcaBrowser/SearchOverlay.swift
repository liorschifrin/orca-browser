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
    var showsIncognitoToggle = false
    @Binding var isIncognito: Bool
    let onAppend: () -> Void
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text = ""
    @State private var selection: TextSelection?
    private let clipboardCache = ClipboardCache.shared
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
                if !clipboardText.isEmpty && clipboardText != text {
                    clipboardChip
                }
                if clipboardCache.access == .needsPermission {
                    pastePermissionChip
                }
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
                text = initialText
                isFocused = true
                clipboardCache.refresh(userInitiated: true)
            }
        }
        .onChange(of: isPresented) { _, nowPresented in
            if nowPresented {
                text = initialText
                isFocused = true
                clipboardCache.refresh(userInitiated: true)
            } else {
                isFocused = false
            }
        }
        // Back from Settings with search still open: pick up a changed choice.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isPresented { clipboardCache.refresh(userInitiated: true) }
        }
        .onChange(of: isFocused) { _, focused in
            if focused, selectInitialText, !text.isEmpty {
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            } else if !focused {
                selection = nil
            }
        }
    }

    private var clipboardText: String {
        clipboardCache.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shows what was copied; tapping goes straight to it.
    private var clipboardChip: some View {
        Button {
            onSubmit(clipboardText)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                Text(clipboardText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.regularMaterial, in: .capsule)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Go to copied text: \(clipboardText)")
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
        HStack(spacing: 10) {
            Button(action: appendToSearch) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to search")
            .accessibilityHint("Moves the cursor to the end with a space ready for more text")

            TextField("Search or enter address", text: $text, selection: $selection)
                .focused($isFocused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)

            if showsIncognitoToggle || isIncognito {
                incognitoToggle
            }

            // Always laid out so the field's width doesn't change when it appears.
            let showsClear = !text.isEmpty
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .opacity(showsClear ? 1 : 0)
            .disabled(!showsClear)
            .accessibilityHidden(!showsClear)
            .accessibilityLabel("Clear")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
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
            onSubmit(text)
        }
    }

    private func appendToSearch() {
        onAppend()
        // Preserve the entry itself; normalize only its trailing whitespace.
        while text.last?.isWhitespace == true { text.removeLast() }
        if !text.isEmpty { text.append(" ") }
        isFocused = true
        selection = TextSelection(insertionPoint: text.endIndex)
    }

    private func dismiss() {
        isFocused = false
        onDismiss()
    }
}
