import SwiftUI

/// The "type a search or address" sheet: a blurred backdrop with the text
/// field at the bottom, riding just above the keyboard (easy for one thumb).
struct SearchOverlay: View {
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text = ""
    @State private var appeared = false

    /// @FocusState tracks (and controls) whether the field has the keyboard.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop: tapping anywhere outside the field dismisses.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            field
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .offset(y: appeared ? 0 : 24)
                .opacity(appeared ? 1 : 0)
        }
        // Swiping down also dismisses.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 40 { dismiss() }
                }
        )
        .onAppear {
            // Ask for the keyboard immediately, in the same moment the
            // overlay appears, so the two animate up together.
            isFocused = true
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                appeared = true
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search or enter address", text: $text)
                .focused($isFocused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear")
            }
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
            onSubmit(trimmed)
        }
    }

    private func dismiss() {
        isFocused = false
        onDismiss()
    }
}
