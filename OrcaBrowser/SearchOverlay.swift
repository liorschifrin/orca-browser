import SwiftUI

/// The "type a search or address" sheet: a blurred backdrop with the text
/// field at the bottom, riding just above the keyboard (easy for one thumb).
///
/// This view stays in the hierarchy permanently and just fades in and out.
/// That keeps the text field "warm" so the keyboard can appear right away.
struct SearchOverlay: View {
    let isPresented: Bool
    /// Text the field starts with each time the overlay opens.
    var initialText = ""
    var selectInitialText = false
    var showsIncognitoToggle = false
    /// Everything typed there is private already, so there's nothing to toggle.
    var isInIncognitoWindow = false
    @Binding var isIncognito: Bool
    let onAppend: () -> Void
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text = ""
    @State private var hasEditedText = false
    @State private var isShowingClipboard = false
    @State private var selection: TextSelection?
    private let clipboardCache = ClipboardCache.shared
    private let settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase

    /// @FocusState tracks (and controls) whether the field has the keyboard.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // Backdrop: tapping anywhere outside the field dismisses.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
                    // Incognito darkens the whole screen, so it's obvious at a glance.
                    Color.black.opacity(isIncognito ? 0.55 : 0)
                }
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            if isIncognito {
                Text("You’re browsing Incognito")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 10) {
                if settings.savesClipboardHistory {
                    if isShowingClipboard {
                        ClipboardPanel(onSelect: insertFromHistory, onShowAll: ClipboardOverlay.shared.showAll)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }
                ClipboardControls(
                    isOpen: $isShowingClipboard,
                    showsHistory: settings.savesClipboardHistory,
                    text: clipboardText,
                    accessibilityText: shouldNavigateClipboard ? "Go to copied text" : "Paste copied text",
                    action: useClipboard
                )
                if clipboardCache.access == .needsPermission {
                    pastePermissionChip
                }
                if let answer = SmartSearchAnswer.evaluate(text) {
                    HStack(spacing: 10) {
                        Image(systemName: "equal")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(answer.result)
                                .font(.headline)
                                .textSelection(.enabled)
                            Text(answer.kind)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = answer.result
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Copy result")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
                field
            }
                .animation(.snappy(duration: 0.2), value: isShowingClipboard)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .offset(y: isPresented ? 0 : 24)
        }
        .environment(\.colorScheme, isIncognito ? .dark : systemColorScheme)
        .animation(.easeOut(duration: 0.2), value: isIncognito)
        .opacity(isPresented ? 1 : 0)
        // While invisible, it must not steal taps or show up for VoiceOver.
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        // Swiping down also dismisses.
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height > 40 { dismiss() }
                }
        )
        .onAppear {
            // Presented at launch: grab the keyboard right away.
            if isPresented {
                text = initialText
                hasEditedText = false
                isFocused = true
                clipboardCache.refresh(userInitiated: true)
            }
        }
        .onChange(of: isPresented) { _, nowPresented in
            if nowPresented {
                text = initialText
                hasEditedText = false
                isFocused = true
                clipboardCache.refresh(userInitiated: true)
            } else {
                isFocused = false
                isShowingClipboard = false
            }
        }
        // Back from Settings with search still open: pick up a changed choice.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isPresented { clipboardCache.refresh(userInitiated: true) }
        }
        .onChange(of: isFocused) { _, focused in
            if focused, selectInitialText, !text.isEmpty {
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            } else if !focused {
                selection = nil
            }
        }
        .onChange(of: text) { _, newText in
            if newText != initialText { hasEditedText = true }
        }
    }

    private var clipboardText: String {
        clipboardCache.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldNavigateClipboard: Bool {
        Self.shouldNavigateClipboard(text: text, hasEditedText: hasEditedText)
    }

    static func shouldNavigateClipboard(text: String, hasEditedText: Bool) -> Bool {
        text.isEmpty || !hasEditedText
    }

    private func useClipboard() {
        isShowingClipboard = false
        if shouldNavigateClipboard {
            onSubmit(clipboardText)
        } else {
            ClipboardHistory.typeIntoField(clipboardCache.text)
        }
    }

    /// Shown whenever pasting has been refused or prompted, until a quick read
    /// shows "Paste from Other Apps" is set to Allow.
    private var pastePermissionChip: some View {
        Button(action: clipboardCache.openSettings) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                Text("Always allow paste in Settings")
                    .lineLimit(1)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.regularMaterial, in: .capsule)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint("Opens Settings so the clipboard can be read without asking each time")
    }

    private var field: some View {
        HStack(spacing: 10) {
            Button(action: appendToSearch) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to search")
            .accessibilityHint("Moves the cursor to the end with a space ready for more text")

            TextField("Search or enter address", text: $text, selection: $selection)
                .focused($isFocused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)

            if !isInIncognitoWindow, showsIncognitoToggle || isIncognito {
                incognitoToggle
            }

            // Always laid out so the field's width doesn't change when it appears.
            let showsClear = !text.isEmpty
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .opacity(showsClear ? 1 : 0)
            .disabled(!showsClear)
            .accessibilityHidden(!showsClear)
            .accessibilityLabel("Clear")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.regularMaterial, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    /// Flips between normal and Incognito while the query is being typed;
    /// the field keeps its text and the keyboard stays up.
    private var incognitoToggle: some View {
        Button {
            isIncognito.toggle()
        } label: {
            HStack(spacing: 8) {
                if isIncognito {
                    Text("Incognito")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isIncognito ? "eye.slash.fill" : "eye.slash")
                    .font(.system(size: 18))
                    .foregroundStyle(isIncognito ? Color.primary : Color.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!showsIncognitoToggle)
        .accessibilityLabel("Incognito")
        .accessibilityValue(isIncognito ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            dismiss()
        } else {
            onSubmit(text)
        }
    }

    private func appendToSearch() {
        onAppend()
        // Preserve the entry itself; normalize only its trailing whitespace.
        while text.last?.isWhitespace == true { text.removeLast() }
        if !text.isEmpty { text.append(" ") }
        isFocused = true
        selection = TextSelection(insertionPoint: text.endIndex)
    }

    /// Types the item where the cursor is, without submitting, and puts it
    /// back on the clipboard at the top of the history.
    private func insertFromHistory(_ item: ClipboardItem) {
        isShowingClipboard = false
        ClipboardHistory.shared.insert(item)
    }

    private func dismiss() {
        isFocused = false
        onDismiss()
    }
}


// MARK: - Offline smart search answers

enum SmartSearchAnswer {
    struct Answer {
        let result: String
        let kind: String
    }

    static func evaluate(_ raw: String, now: Date = Date(), localZone: TimeZone = .current) -> Answer? {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        return time(query, now: now, localZone: localZone)
            ?? conversion(query)
            ?? calculation(query)
    }

    private static func formatted(_ number: Double) -> String {
        guard number.isFinite else { return "" }
        return number.formatted(.number.precision(.fractionLength(0...6)))
    }

    private static func time(_ query: String, now: Date, localZone: TimeZone) -> Answer? {
        let pattern = #"^([0-9]{1,2}):([0-9]{2})\s*(am|pm)?\s*(pt|pst|pdt|et|est|edt|ct|cst|cdt|mt|mst|mdt|utc|gmt)$"#
        guard let match = query.lowercased().range(of: pattern, options: .regularExpression) else { return nil }
        let parts = query.lowercased()[match].split(whereSeparator: { $0.isWhitespace })
        let compact = parts.joined(separator: " ")
        let pattern2 = #"^([0-9]{1,2}):([0-9]{2})\s*(am|pm)?\s*(pt|pst|pdt|et|est|edt|ct|cst|cdt|mt|mst|mdt|utc|gmt)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern2),
              let m = regex.firstMatch(in: compact, range: NSRange(compact.startIndex..., in: compact)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: compact) else { return nil }
            return String(compact[range])
        }
        guard let hour = Int(group(1) ?? ""), let minute = Int(group(2) ?? ""),
              hour <= 23, minute <= 59, let abbreviation = group(4) else { return nil }
        let meridiem = group(3)
        guard meridiem == nil || (1...12).contains(hour) else { return nil }
        let zoneID: String
        switch abbreviation {
        case "pt", "pst", "pdt": zoneID = "America/Los_Angeles"
        case "et", "est", "edt": zoneID = "America/New_York"
        case "ct", "cst", "cdt": zoneID = "America/Chicago"
        case "mt", "mst", "mdt": zoneID = "America/Denver"
        default: zoneID = "Etc/UTC"
        }
        guard let source = TimeZone(identifier: zoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = source
        let sourceHour: Int
        if let meridiem {
            sourceHour = (hour % 12) + (meridiem == "pm" ? 12 : 0)
        } else if hour > 12 || hour == 0 {
            sourceHour = hour
        } else {
            // A bare 8:30 could mean AM or PM. Do not guess.
            return Answer(result: "Specify AM or PM", kind: "Time zone conversion")
        }
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        var components = today
        components.hour = sourceHour
        components.minute = minute
        guard let date = calendar.date(from: components) else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = localZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return Answer(result: formatter.string(from: date), kind: "Local time (\(localZone.abbreviation(for: date) ?? localZone.identifier))")
    }

    private struct Unit {
        let dimension: String
        let factor: Double
        let offset: Double
        let label: String
    }

    private static let units: [String: Unit] = {
        var result: [String: Unit] = [:]
        func add(_ aliases: [String], _ dimension: String, _ factor: Double, _ label: String, offset: Double = 0) {
            for alias in aliases { result[alias] = Unit(dimension: dimension, factor: factor, offset: offset, label: label) }
        }
        add(["m", "meter", "meters"], "length", 1, "m")
        add(["km", "kilometer", "kilometers"], "length", 1000, "km")
        add(["mi", "mile", "miles"], "length", 1609.344, "mi")
        add(["ft", "foot", "feet"], "length", 0.3048, "ft")
        add(["in", "inch", "inches"], "length", 0.0254, "in")
        add(["cm"], "length", 0.01, "cm")
        add(["mm"], "length", 0.001, "mm")
        add(["kg", "kilogram", "kilograms"], "mass", 1, "kg")
        add(["g", "gram", "grams"], "mass", 0.001, "g")
        add(["lb", "lbs", "pound", "pounds"], "mass", 0.45359237, "lb")
        add(["oz", "ounce", "ounces"], "mass", 0.028349523125, "oz")
        add(["l", "liter", "liters", "litre", "litres"], "volume", 1, "L")
        add(["ml", "milliliter", "milliliters"], "volume", 0.001, "mL")
        add(["gal", "gallon", "gallons"], "volume", 3.785411784, "US gal")
        add(["cup", "cups"], "volume", 0.2365882365, "US cups")
        add(["sqm", "m2"], "area", 1, "m²")
        add(["sqft", "ft2"], "area", 0.09290304, "ft²")
        add(["c", "celsius"], "temperature", 1, "°C")
        add(["f", "fahrenheit"], "temperature", 5.0 / 9, "°F", offset: -32)
        add(["k", "kelvin"], "temperature", 1, "K", offset: -273.15)
        return result
    }()

    private static func conversion(_ query: String) -> Answer? {
        let pattern = #"^(-?\d+(?:\.\d+)?)\s*([a-z0-9]+)\s+(?:to|in)\s+([a-z0-9]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)),
              match.numberOfRanges == 4,
              let amountRange = Range(match.range(at: 1), in: query),
              let fromRange = Range(match.range(at: 2), in: query),
              let toRange = Range(match.range(at: 3), in: query),
              let amount = Double(query[amountRange]),
              let from = units[String(query[fromRange]).lowercased()],
              let to = units[String(query[toRange]).lowercased()],
              from.dimension == to.dimension else { return nil }
        let base = (amount + from.offset) * from.factor
        let converted = base / to.factor - to.offset
        return Answer(result: "\(formatted(converted)) \(to.label)", kind: "Unit conversion")
    }

    private static func calculation(_ query: String) -> Answer? {
        // Restrict inputs to arithmetic, never execute user input as code.
        let normalized = query.replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
        guard normalized.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")) != nil,
              normalized.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.+-*/()% ").inverted) == nil,
              normalized.contains(where: { "+-*/%".contains($0) }) else { return nil }
        var parser = ArithmeticParser(Array(normalized))
        guard let value = parser.parse(), value.isFinite else { return nil }
        return Answer(result: formatted(value), kind: "Calculation")
    }

    private struct ArithmeticParser {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) { self.characters = characters }

        mutating func skipSpaces() {
            while index < characters.count && characters[index].isWhitespace { index += 1 }
        }

        mutating func consume(_ char: Character) -> Bool {
            skipSpaces()
            guard index < characters.count && characters[index] == char else { return false }
            index += 1
            return true
        }

        mutating func parse() -> Double? {
            guard let value = expression() else { return nil }
            skipSpaces()
            return index == characters.count ? value : nil
        }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while true {
                if consume("+") {
                    guard let next = term() else { return nil }
                    value += next
                } else if consume("-") {
                    guard let next = term() else { return nil }
                    value -= next
                } else { return value }
            }
        }

        mutating func term() -> Double? {
            guard var value = factor() else { return nil }
            while true {
                if consume("*") {
                    guard let next = factor() else { return nil }
                    value *= next
                } else if consume("/") {
                    guard let next = factor(), next != 0 else { return nil }
                    value /= next
                } else { return value }
            }
        }

        mutating func factor() -> Double? {
            if consume("-") { return factor().map { -$0 } }
            if consume("+") { return factor() }
            if consume("(") {
                guard let value = expression(), consume(")") else { return nil }
                return percentage(value)
            }
            skipSpaces()
            let start = index
            while index < characters.count && (characters[index].isNumber || characters[index] == ".") {
                index += 1
            }
            guard start < index, let value = Double(String(characters[start..<index])) else { return nil }
            return percentage(value)
        }

        mutating func percentage(_ value: Double) -> Double {
            consume("%") ? value / 100 : value
        }
    }
}
