import SwiftUI

/// A compact solid token in the site's colour, shared by the suggestion row
/// and the search field. It is only as wide as its name.
struct SearchProviderChip: View {
    let provider: SearchProvider
    var showsClose = false
    /// Highlighted like selected text: typing will replace it.
    var isSelected = false
    /// Taller where it sits beside other controls of that height; everything scales with it.
    var height: CGFloat = 22

    var body: some View {
        let fill = SiteAppearance.color(siteID: provider.id, host: provider.domain, setting: provider.color)
        let text: Color = SiteColors.isLight(fill) ? .black : .white
        let scale = height / 22
        HStack(spacing: 3 * scale) {
            SiteIconView(icon: provider.icon, siteID: provider.id, host: provider.domain, tint: SiteColors.isLight(fill) ? .black : fill)
                .frame(width: 11 * scale, height: 11 * scale)
                .frame(width: 16 * scale, height: 16 * scale)
                .background(.white, in: .circle)
                .accessibilityHidden(true)
            Text(displayName)
                .font(.system(size: min(11 * scale, 15), weight: .bold))
                .lineLimit(1)
                .truncationMode(.tail)
            if showsClose {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .black))
                    .opacity(0.75)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(text)
        .padding(.leading, 3 * scale)
        .padding(.trailing, 7 * scale)
        .frame(height: height)
        .background(fill, in: .capsule)
        .overlay {
            if isSelected { Capsule().fill(Color.accentColor.opacity(0.55)) }
        }
        // Exactly as wide as its name, wherever it is placed.
        .fixedSize(horizontal: true, vertical: false)
        // The chip is small; the tap area around it is not.
        .padding(.vertical, max(0, 36 - height) / 2)
        .contentShape(.rect)
    }

    private var displayName: String {
        provider.name.count > 18 ? provider.name.prefix(17) + "…" : provider.name
    }
}
