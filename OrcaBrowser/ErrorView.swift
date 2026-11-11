import SwiftUI

/// Shown instead of a blank page when a load fails.
struct ErrorView: View {
    let error: Tab.LoadError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: error.symbol)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Can’t Open Page")
                .font(.title3.weight(.semibold))

            Text(error.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
