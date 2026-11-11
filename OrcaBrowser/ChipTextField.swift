import SwiftUI
import UIKit

/// Where to put the field's cursor, in UTF-16 units of what it shows (the
/// chip counts as one). Each request is applied once.
struct FieldSelectionRequest: Equatable {
    enum Kind: Equatable {
        case caret(Int)
        case all
    }

    let kind: Kind
    let id = UUID()

    static func caret(_ offset: Int) -> Self { Self(kind: .caret(offset)) }
    static var all: Self { Self(kind: .all) }
}

/// The search field. The site chip sits inside the text as a single
/// character, so selecting, highlighting, cutting and deleting treat it like
/// any other letter, with the system's own selection look.
///
/// It's a text view rather than a text field: a text field drops image
/// characters while it's being edited. Long text wraps, up to a few lines.
struct ChipTextField: UIViewRepresentable {
    let placeholder: String
    /// What's typed after the chip (or all of it when there is no chip).
    @Binding var text: String
    /// The chip, drawn, and what identifies it; nil when there is no chip.
    let chip: UIImage?
    let chipID: String?
    /// The shortcut the chip stands for, written out when the chip is copied.
    var chipWord = ""
    @Binding var isFocused: Bool
    var selectionRequest: FieldSelectionRequest?
    /// Delete reached the chip and nothing else: it turns back into its word.
    let onDeleteChip: (_ query: String) -> Void
    /// An edit took the chip along with other text: what's left, and where the cursor goes.
    let onReplaceChip: (_ text: String, _ caret: Int) -> Void
    let onTapChip: () -> Void
    /// After each change typed into the field; `text` is already updated.
    let onEdit: () -> Void
    let onSubmit: () -> Void

    static let chipCharacter = "\u{FFFC}"

    /// A selection as copied: the chip becomes its shortcut ("yt lofi"), which
    /// pastes back as the chip, with a space only when text follows it.
    /// Everything else is kept exactly, spaces included.
    static func copied(_ selected: String, chipWord: String) -> String {
        guard let chip = selected.range(of: chipCharacter) else { return selected }
        var result = selected
        let separator = chipWord.isEmpty || selected[chip.upperBound...].isEmpty ? "" : " "
        result.replaceSubrange(chip, with: chipWord + separator)
        return result
    }

    /// Pasted lines joined with spaces. Splits on every kind of line break the
    /// field checks for, so the result never needs joining again.
    static func oneLine(_ string: String) -> String {
        guard string.contains(where: \.isNewline) else { return string }
        return string.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    static let verticalInset: CGFloat = 14

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.coordinator = context.coordinator
        field.delegate = context.coordinator
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.backgroundColor = .clear
        field.keyboardType = .webSearch
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.returnKeyType = .go
        field.accessibilityIdentifier = "search-query"
        // The space above and below is part of the field, so a tap there
        // still places the cursor (or ends a selection).
        field.textContainerInset = UIEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        field.textContainer.lineFragmentPadding = 0
        // Addresses have no spaces; break them anywhere rather than overflow.
        field.textContainer.lineBreakMode = .byCharWrapping
        field.showsVerticalScrollIndicator = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        field.addGestureRecognizer(tap)
        return field
    }

    /// As tall as its text, up to four lines; past that it scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: Field, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let line = ceil((field.font ?? .preferredFont(forTextStyle: .body)).lineHeight)
        let fitted = field.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let insets = Self.verticalInset * 2
        return CGSize(width: width, height: min(max(line + insets, ceil(fitted)), line * 4 + insets))
    }

    func updateUIView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.accessibilityLabel = placeholder
        // Never rebuild under the keyboard's own unfinished input (marked text).
        if field.markedTextRange == nil,
           coordinator.shownChipID != chipID || coordinator.query(in: field) != text {
            coordinator.shownChipID = chipID
            field.attributedText = coordinator.attributed(text, chip: chip, font: field.font ?? .preferredFont(forTextStyle: .body))
            field.typingAttributes = coordinator.textAttributes(field)
            coordinator.keepCaretVisible(field)
        }
        if let request = selectionRequest, request.id != coordinator.appliedRequestID {
            coordinator.appliedRequestID = request.id
            coordinator.apply(request, to: field)
        }
        field.wantsFocus = isFocused
        if isFocused, !field.isFirstResponder, field.window != nil {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Field: UITextView {
        weak var coordinator: Coordinator?
        var wantsFocus = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, wantsFocus, !isFirstResponder { becomeFirstResponder() }
        }

        // The chip is a stand-in character; what's copied is the text.
        override func copy(_ sender: Any?) {
            guard selectedRange.length > 0 else { return }
            UIPasteboard.general.string = ChipTextField.copied(
                (text as NSString).substring(with: selectedRange), chipWord: coordinator?.parent.chipWord ?? "")
        }

        override func cut(_ sender: Any?) {
            copy(sender)
            // Cutting the chip removes it, unlike deleting into it.
            coordinator?.isCutting = true
            coordinator?.replace(selectedRange, with: "", in: self)
            coordinator?.isCutting = false
        }

        // Pasted text takes the field's own style, on one line.
        override func paste(_ sender: Any?) {
            guard let string = UIPasteboard.general.string else { return }
            coordinator?.replace(selectedRange, with: string, in: self)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ChipTextField
        var shownChipID: String?
        var appliedRequestID: UUID?
        var isCutting = false

        init(_ parent: ChipTextField) { self.parent = parent }

        /// What's typed, without the chip.
        func query(in field: UITextView) -> String {
            let shown = field.text ?? ""
            return shown.hasPrefix(ChipTextField.chipCharacter) ? String(shown.dropFirst()) : shown
        }

        func textAttributes(_ field: UITextView) -> [NSAttributedString.Key: Any] {
            [.font: field.font ?? UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label]
        }

        func attributed(_ text: String, chip: UIImage?, font: UIFont) -> NSAttributedString {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            let result = NSMutableAttributedString()
            if let chip {
                let attachment = NSTextAttachment(image: chip)
                // Centred on the letters, not the line.
                attachment.bounds = CGRect(x: 0, y: (font.capHeight - chip.size.height) / 2,
                                           width: chip.size.width, height: chip.size.height)
                result.append(NSAttributedString(attachment: attachment))
                result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
            return result
        }

        func apply(_ request: FieldSelectionRequest, to field: UITextView) {
            let select = { [weak self] in
                let length = (field.text as NSString).length
                switch request.kind {
                case .all:
                    field.selectedRange = NSRange(location: 0, length: length)
                case .caret(let offset):
                    field.selectedRange = NSRange(location: min(max(0, offset), length), length: 0)
                }
                self?.keepCaretVisible(field)
            }
            select()
            // Gaining focus places the cursor itself; select again once it has.
            if request.kind == .all { DispatchQueue.main.async(execute: select) }
        }

        func keepCaretVisible(_ field: UITextView) {
            field.scrollRangeToVisible(field.selectedRange)
        }

        /// Makes an edit the way typing would, through the same rules.
        func replace(_ range: NSRange, with string: String, in field: UITextView) {
            let oneLine = ChipTextField.oneLine(string)
            guard textView(field, shouldChangeTextIn: range, replacementText: oneLine) else { return }
            field.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: oneLine, attributes: textAttributes(field)))
            field.selectedRange = NSRange(location: range.location + (oneLine as NSString).length, length: 0)
            textViewDidChange(field)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
            if string == "\n" {
                parent.onSubmit()
                return false
            }
            if string.contains(where: \.isNewline) {
                replace(range, with: string, in: textView)
                return false
            }
            guard shownChipID != nil, range.location == 0, range.length > 0 else { return true }
            let shown = (textView.text ?? "") as NSString
            if range.length == 1, string.isEmpty, !isCutting {
                parent.onDeleteChip(shown.substring(from: 1))
            } else {
                // Typed over, cut or pasted over a selection that includes the chip.
                let replaced = shown.replacingCharacters(in: range, with: string)
                    .replacingOccurrences(of: ChipTextField.chipCharacter, with: "")
                parent.onReplaceChip(replaced, (string as NSString).length)
            }
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            keepCaretVisible(textView)
            guard textView.markedTextRange == nil else { return }
            let shown = textView.text ?? ""
            // The chip went without asking first (some edits skip that step).
            if shownChipID != nil, !shown.contains(ChipTextField.chipCharacter) {
                shownChipID = nil
                if shown == parent.text {
                    parent.onDeleteChip(shown)
                } else {
                    parent.onReplaceChip(shown, textView.selectedRange.location)
                }
                return
            }
            let query = query(in: textView)
            if parent.text != query { parent.text = query }
            parent.onEdit()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.typingAttributes = textAttributes(textView)
            // Nothing can be typed before the chip.
            if shownChipID != nil, textView.selectedRange == NSRange(location: 0, length: 0),
               (textView.text as NSString).length > 0 {
                textView.selectedRange = NSRange(location: 1, length: 0)
            }
            keepCaretVisible(textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        // A tap on the chip (its ×) turns it back into its word; other taps
        // place the cursor as usual.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard shownChipID != nil, let field = recognizer.view as? UITextView else { return false }
            // Where the chip really is, on its own line: the text after it and
            // wrapped text below it are ordinary text.
            let layout = field.layoutManager
            let chip = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: field.textContainer)
            let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let inset = field.textContainerInset
            // A little extra to the left and into the margin above, where there's no text.
            let hit = CGRect(x: chip.minX + inset.left - 8, y: line.minY,
                             width: chip.width + 8, height: line.maxY + inset.top)
            return hit.contains(recognizer.location(in: field))
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            parent.onTapChip()
        }
    }
}

/// Draws a site chip once for use inside the field's text.
@MainActor
enum ChipImages {
    private static var cache: [String: UIImage] = [:]

    static func image(for provider: SearchProvider, scale: CGFloat) -> UIImage? {
        let hasIcon = SiteIconStore.shared.image(forHost: provider.domain) != nil
        let key = "\(provider.id)|\(provider.name)|\(provider.color)|\(provider.icon)|\(hasIcon)|\(scale)"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content:
            SearchProviderChip(provider: provider, showsClose: true, hasTapPadding: false)
                // The gap before the text is part of the chip's character.
                .padding(.trailing, 6)
        )
        renderer.scale = scale
        guard let image = renderer.uiImage else { return nil }
        if cache.count > 30 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
