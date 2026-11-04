import SwiftUI

/// Shown after Face ID, when the incognito window still has tabs in it.
struct IncognitoChoiceSheet: View {
    let onContinue: () -> Void
    let onStartFresh: () -> Void

    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 34))
                .foregroundStyle(.purple)
            Text("Your incognito tabs are still open")
                .font(.headline)

            Button(action: onContinue) {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Start Fresh", role: .destructive) { isConfirming = true }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .padding(24)
        .presentationDetents([.height(300)])
        .confirmationDialog(
            "Close all incognito tabs and forget what they stored?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Start Fresh", role: .destructive, action: onStartFresh)
        }
    }
}
