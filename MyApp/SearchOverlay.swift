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
    let onAppend: () -> Void
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text = ""
    @State private var selection: TextSelection?
    private let clipboardCache = ClipboardCache.shared

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
                if !clipboardText.isEmpty && clipboardText != text {
                    clipboardChip
                }
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
                    if value.translation.height > 40 { dismiss() }
                }
        )
        .onAppear {
            // Presented at launch: grab the keyboard right away.
            if isPresented {
                text = initialText
                isFocused = true
                clipboardCache.refresh()
            }
        }
        .onChange(of: isPresented) { _, nowPresented in
            if nowPresented {
                text = initialText
                isFocused = true
                clipboardCache.refresh()
            } else {
                isFocused = false
            }
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
