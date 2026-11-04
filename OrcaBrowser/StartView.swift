import SwiftUI

/// What an empty tab looks like.
struct StartView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 44, weight: .light))
            Text("New Tab")
                .font(.title3.weight(.semibold))
            Text("Tap + to search or enter an address")
                .font(.subheadline)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}
