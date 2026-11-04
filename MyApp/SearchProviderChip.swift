import SwiftUI

/// A compact brand-tinted token, shared by the suggestion row and search field.
/// The entire selected token is a remove button, including the × on its right.
struct SearchProviderChip: View {
    let provider: SearchProvider
    var showsClose = false

    var body: some View {
        HStack(spacing: 6) {
            icon
                .frame(width: 22, height: 22)
                .background(.white, in: .circle)
                .accessibilityHidden(true)
            Text(provider.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 88)
            if showsClose {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.primary)
        .padding(.leading, 5)
        .padding(.trailing, showsClose ? 9 : 10)
        .frame(height: 32)
        .background(brandColor.opacity(0.16), in: .capsule)
        .overlay { Capsule().strokeBorder(brandColor.opacity(0.3), lineWidth: 0.75) }
        .frame(minHeight: 44)
        .contentShape(.capsule)
    }

    @ViewBuilder
    private var icon: some View {
        if let asset {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .foregroundStyle(logoColor)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(logoColor)
        }
    }

    private var asset: String? {
        switch provider.id {
        case "youtube": "ProviderYoutube"
        case "wikipedia": "ProviderWikipedia"
        case "reddit": "ProviderReddit"
        case "amazon": "ProviderAmazon"
        case "google-images": "ProviderGoogle"
        case "google-translate": "ProviderGoogletranslate"
        case "imdb": "ProviderImdb"
        default: nil
        }
    }

    private var brandColor: Color {
        switch provider.id {
        case "youtube": Color(red: 1, green: 0, blue: 0)
        case "wikipedia": .gray
        case "reddit": Color(red: 1, green: 0.27, blue: 0)
        case "amazon": Color(red: 1, green: 0.60, blue: 0)
        case "google-images", "google-translate": Color(red: 0.26, green: 0.52, blue: 0.96)
        case "imdb": Color(red: 0.96, green: 0.77, blue: 0.09)
        default: .accentColor
        }
    }

    private var logoColor: Color {
        switch provider.id {
        case "wikipedia", "imdb": .black
        default: brandColor
        }
    }
}
