import SwiftUI

/// Full-screen overview of open tabs: a two-column grid of cards.
struct TabSwitcher: View {
    let store: BrowserStore
    let onSelect: (Tab) -> Void
    let onClose: (Tab) -> Void
    let onNewTab: () -> Void
    let onDone: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(store.tabs) { tab in
                        TabCard(
                            tab: tab,
                            isSelected: tab.id == store.selectedTabID,
                            onSelect: { onSelect(tab) },
                            onClose: { onClose(tab) }
                        )
                        // When a card is removed, neighbors glide into place.
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            // Cards scroll under the bar, which reserves room for itself.
            .contentMargins(.bottom, 90, for: .scrollContent)

            controls
        }
    }

    /// Mirrors the browser's bottom bar so it feels like the same place.
    private var controls: some View {
        HStack {
            Text(store.tabs.count == 1 ? "1 Tab" : "\(store.tabs.count) Tabs")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            NewTabButton(action: onNewTab)

            Button("Done", action: onDone)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
