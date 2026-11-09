import SwiftUI

/// Ways to lay out search suggestions, the clipboard and the field, to try
/// side by side on the phone. Switched from the pill above the search field
/// or in Settings.
enum SuggestionLook: String, CaseIterable, Identifiable {
    /// Suggestions in their own card, the clipboard chip centered below it.
    case current
    /// Suggestions, clipboard and field in one panel.
    case panel
    /// The clipboard is the bottom row of the suggestions card.
    case clipboardRow
    /// No card: suggestions sit on the blur, lined up with the field's text.
    case floating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: "Current"
        case .panel: "One panel"
        case .clipboardRow: "Clipboard in list"
        case .floating: "Floating"
        }
    }
}

/// One suggestion on one line: what was typed is dimmed and Google's
/// completion is bold, so the new part is what stands out.
struct SuggestionRowLabel: View {
    let suggestion: String
    let typed: String
    var showsIcon = true

    var body: some View {
        // Spaced so the text starts where the field's text does.
        HStack(spacing: 20) {
            if showsIcon {
                Image(systemName: "magnifyingglass")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
            }
            // What was typed is the same on every row and sits right below in
            // the field, so only its last word is kept to lead into the completion.
            highlighted(prefix: matchedPrefix.map(Self.lastWord) ?? "")
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
    }

    /// The part of the suggestion that is what was typed, if it starts with it.
    private var matchedPrefix: String? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let range = suggestion.range(of: trimmed, options: [.caseInsensitive, .anchored]) else { return nil }
        return String(suggestion[range])
    }

    private var completion: Substring {
        suggestion.dropFirst(matchedPrefix?.count ?? 0)
    }

    private func highlighted(prefix: String) -> some View {
        let shown = prefix.count < (matchedPrefix?.count ?? 0) ? "…" + prefix : prefix
        return (Text(shown).foregroundStyle(.secondary)
            + Text(completion).fontWeight(matchedPrefix == nil ? .regular : .semibold))
            .lineLimit(1)
    }

    /// "when was the eif" → "eif", so "…eif|fel tower built" still reads.
    static func lastWord(_ text: String) -> String {
        guard let space = text.lastIndex(where: \.isWhitespace) else { return text }
        return String(text[text.index(after: space)...])
    }
}

/// The clipboard as a row: what's on it, and what tapping does.
struct ClipboardSuggestionRow: View {
    let text: String
    /// Opens it rather than typing it into the field.
    let navigates: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: "doc.on.clipboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                label
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(navigates ? "Paste & Go" : "Paste")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color.accentColor.opacity(0.15), in: .capsule)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(navigates ? "Go to copied text" : "Paste copied text"): \(text)")
    }

    /// A link reads as its site, then the rest dimmed: "youtube.com /watch?v=…".
    private var label: Text {
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
              var host = url.host(), !text.contains(where: \.isWhitespace) else {
            return Text(text).foregroundStyle(.secondary)
        }
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        let rest = text.drop(while: { $0 != "/" }).dropFirst(2).drop(while: { $0 != "/" })
        return Text(host) + Text(rest == "/" ? "" : rest).foregroundStyle(.secondary)
    }
}

/// The clipboard history button without its own circle, for inside a panel.
struct InlineClipboardButton: View {
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: isOpen ? "clipboard.fill" : "clipboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isOpen ? Color.primary : Color.secondary)
                .frame(width: 40, height: 40)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clipboard history")
        .accessibilityAddTraits(isOpen ? .isSelected : [])
    }
}

/// Temporary: a pill at the top of the search screen to flip between looks.
struct SuggestionLookPicker: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Menu {
            Picker("Suggestion look", selection: $settings.suggestionLook) {
                ForEach(SuggestionLook.allCases) { look in
                    Text(look.title).tag(look)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paintpalette")
                Text("Look: \(settings.suggestionLook.title)")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(.regularMaterial, in: .capsule)
        }
        .accessibilityIdentifier("suggestion-look-picker")
    }
}
