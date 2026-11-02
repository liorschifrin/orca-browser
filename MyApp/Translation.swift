import NaturalLanguage
import UIKit

/// Works out whether a page is in another language, and hands it to Google
/// Chrome (which can translate it) when asked.
enum Translation {
    /// The text is the better evidence: pages often declare the wrong
    /// language (or none). The declared language is the fallback for pages
    /// with too little text to tell.
    nonisolated static func isForeign(declared: String, text: String) -> Bool {
        let readable = Set(Locale.preferredLanguages.compactMap {
            Locale(identifier: $0).language.languageCode?.identifier
        })
        guard !readable.isEmpty else { return false }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if text.count >= 80,
           let best = recognizer.dominantLanguage,
           let confidence = recognizer.languageHypotheses(withMaximum: 1)[best],
           confidence >= 0.6 {
            return !readable.contains(Locale(identifier: best.rawValue).language.languageCode?.identifier ?? best.rawValue)
        }

        guard let code = Locale(identifier: declared).language.languageCode?.identifier,
              !declared.isEmpty else { return false }
        return !readable.contains(code)
    }

    private static func chromeURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch url.scheme?.lowercased() {
        case "https": components.scheme = "googlechromes"
        case "http": components.scheme = "googlechrome"
        default: return nil
        }
        return components.url
    }

    /// Whether Chrome is installed (the button is pointless otherwise).
    @MainActor static func canOpenInChrome(_ url: URL?) -> Bool {
        guard let url, let chrome = chromeURL(for: url) else { return false }
        return UIApplication.shared.canOpenURL(chrome)
    }

    @MainActor static func openInChrome(_ url: URL) {
        guard let chrome = chromeURL(for: url) else { return }
        UIApplication.shared.open(chrome)
    }
}
