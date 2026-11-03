import Foundation

/// Matches the ChatGPT app handoff used by the AI integration. Only the
/// dictated prompt is included, with strict query encoding for reserved text.
enum ChatGPTLink {
    static func url(for prompt: String, scheme: String = "com.openai.chat") -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = prompt.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://chatgpt.com/?prompt=\(encoded)")
    }

    /// The fallback is app-only: Bark may itself be the default web browser.
    /// Keeping the opener injectable lets tests verify that no browser tab is
    /// created and that the prompt survives the fallback unchanged.
    static func open(_ url: URL, using openURL: (URL, Bool) async -> Bool) async -> Bool {
        if await openURL(url, false) { return true }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        components.scheme = "https"
        guard let fallback = components.url else { return false }
        return await openURL(fallback, true)
    }
}
