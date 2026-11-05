import SwiftUI

/// A compact solid token in the site's colour, shared by the suggestion row
/// and the search field. It is only as wide as its name.
struct SearchProviderChip: View {
    let provider: SearchProvider
    var showsClose = false

    var body: some View {
        let fill = SiteAppearance.color(siteID: provider.id, host: provider.domain, setting: provider.color)
        let text: Color = SiteColors.isLight(fill) ? .black : .white
        HStack(spacing: 3) {
            SiteIconView(icon: provider.icon, siteID: provider.id, host: provider.domain, tint: SiteColors.isLight(fill) ? .black : fill)
                .frame(width: 11, height: 11)
                .frame(width: 16, height: 16)
                .background(.white, in: .circle)
                .accessibilityHidden(true)
            Text(provider.name)
                .font(.system(size: 11, weight: .bold))
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
        .padding(.leading, 3)
        .padding(.trailing, 7)
        .frame(height: 22)
        .background(fill, in: .capsule)
        .frame(maxWidth: 140)
        // The chip is small; the tap area around it is not.
        .padding(.vertical, 7)
        .contentShape(.rect)
    }
}
