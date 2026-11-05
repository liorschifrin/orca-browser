import SwiftUI

/// A compact solid token in the provider's brand color, shared by the
/// suggestion row and the search field.
struct SearchProviderChip: View {
    let provider: SearchProvider

    var body: some View {
        HStack(spacing: 4) {
            icon
                .frame(width: 18, height: 18)
                .background(.white, in: .circle)
                .accessibilityHidden(true)
            Text(provider.name)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(textColor)
        .padding(.leading, 4)
        .padding(.trailing, 9)
        .frame(height: 26)
        .background(brandColor, in: .capsule)
        .frame(maxWidth: 150)
        .frame(minHeight: 44)
        .contentShape(.capsule)
    }

    @ViewBuilder
    private var icon: some View {
        if let asset {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .foregroundStyle(logoColor)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 10, weight: .medium))
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

    /// Dark text on the light brand colors, white on the rest.
    private var textColor: Color {
        switch provider.id {
        case "imdb", "amazon": .black
        default: .white
        }
    }

    private var logoColor: Color {
        switch provider.id {
        case "wikipedia", "imdb": .black
        default: brandColor
        }
    }
}
