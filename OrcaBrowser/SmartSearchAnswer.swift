import Foundation

/// Answers a search query on the spot, offline: arithmetic, unit conversions
/// and time-zone conversions. Returns nil for anything else, so ordinary
/// searches (phone numbers, dates, plain words) are never touched.
enum SmartSearchAnswer {
    struct Answer: Equatable {
        /// The headline, formatted for reading.
        let result: String
        /// A short line under it saying what was understood.
        let detail: String
        /// What the copy button puts on the clipboard: plain, no digit grouping.
        let copyText: String
    }

    static func evaluate(_ raw: String, now: Date = Date(), localZone: TimeZone = .current) -> Answer? {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200 else { return nil }
        return time(query.lowercased(), now: now, localZone: localZone)
            ?? conversion(query.lowercased())
            ?? calculation(query)
    }

    // MARK: Numbers

    /// Fifteen significant digits hides binary rounding noise (0.1 + 0.2).
    /// Very large and very small values switch to scientific notation rather
    /// than showing a wall of digits or rounding to zero.
    static func format(_ number: Double, grouped: Bool) -> String {
        guard number.isFinite else { return "" }
        let cleaned = Double(String(format: "%.15g", number)) ?? number
        if cleaned == 0 { return "0" }
        let magnitude = abs(cleaned)
        let style = FloatingPointFormatStyle<Double>(locale: grouped ? .current : Locale(identifier: "en_US_POSIX"))
            .grouping(grouped ? .automatic : .never)
        if magnitude >= 1e15 || magnitude < 1e-9 {
            return style.notation(.scientific).precision(.significantDigits(1...7)).format(cleaned)
        }
        if magnitude < 1 {
            return style.precision(.significantDigits(1...10)).format(cleaned)
        }
        return style.precision(.fractionLength(0...8)).format(cleaned)
    }

    // MARK: Calculator

    private static func calculation(_ query: String) -> Answer? {
        // 0x10 is hex, not 0 times 10.
        guard query.range(of: #"(?<![\d.])0[xX]"#, options: .regularExpression) == nil else { return nil }
        var text = query
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "**", with: "^")
        // "3 x 4" multiplies, but only between numbers: "x" is a word elsewhere.
        text = text.replacingOccurrences(of: #"(?<=[\d)])\s*[xX]\s*(?=[\d(])"#, with: "*", options: .regularExpression)
        // "1,000" is a thousand, not two numbers.
        text = text.replacingOccurrences(of: #"(?<=\d),(?=\d{3}(?!\d))"#, with: "", options: .regularExpression)
        // "20% of 150"
        text = text.replacingOccurrences(of: #"(?i)\s+of\s+"#, with: "*", options: .regularExpression)

        let allowed = CharacterSet(charactersIn: "0123456789.+-*/^()% ")
        guard text.rangeOfCharacter(from: allowed.inverted) == nil,
              text.rangeOfCharacter(from: .decimalDigits) != nil,
              !looksLikeDateOrPhoneNumber(text) else { return nil }
        var parser = ArithmeticParser(Array(text))
        guard let value = parser.parse(), parser.operationCount > 0, value.isFinite else { return nil }
        return Answer(
            result: format(value, grouped: true),
            detail: "Calculation",
            copyText: format(value, grouped: false)
        )
    }

    /// Digits joined by "-" or "/" with no spaces are far more often a date,
    /// phone number or zip+4 than a sum. Spaces ("1000 - 250") say it's a sum.
    private static func looksLikeDateOrPhoneNumber(_ text: String) -> Bool {
        text.range(of: #"^\d+(/\d+){2,}$"#, options: .regularExpression) != nil       // 11/5/2024
            || text.range(of: #"^\d+(-\d+){2,}$"#, options: .regularExpression) != nil  // 2024-11-05
            || text.range(of: #"^\d{3,}-\d{3,}$"#, options: .regularExpression) != nil  // 555-1234
    }

    /// Recursive descent, so user input is never executed as code. Percent
    /// follows Google's reading: `100 + 10%` is 110, `50%` alone is 0.5.
    struct ArithmeticParser {
        private let characters: [Character]
        private var index = 0
        private var depth = 0
        /// Binary operators applied, so a lone "5", "-5" or "100%" isn't a sum.
        private(set) var operationCount = 0

        init(_ characters: [Character]) { self.characters = characters }

        mutating func parse() -> Double? {
            guard let value = expression()?.value else { return nil }
            skipSpaces()
            return index == characters.count ? value : nil
        }

        private struct Operand {
            var value: Double
            var isPercent = false
        }

        private mutating func skipSpaces() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }

        private mutating func consume(_ char: Character) -> Bool {
            skipSpaces()
            guard index < characters.count, characters[index] == char else { return false }
            index += 1
            return true
        }

        private mutating func expression() -> Operand? {
            guard var left = term() else { return nil }
            while true {
                let isAdd = consume("+")
                guard isAdd || consume("-") else { return left }
                guard let right = term() else { return nil }
                operationCount += 1
                // "100 + 10%" adds ten percent of 100.
                let amount = right.isPercent ? left.value * right.value : right.value
                left = Operand(value: isAdd ? left.value + amount : left.value - amount)
            }
        }

        private mutating func term() -> Operand? {
            guard var left = unary() else { return nil }
            while true {
                if consume("*") {
                    guard let right = unary() else { return nil }
                    operationCount += 1
                    left = Operand(value: left.value * right.value)
                } else if consume("/") {
                    guard let right = unary(), right.value != 0 else { return nil }
                    operationCount += 1
                    left = Operand(value: left.value / right.value)
                } else {
                    return left
                }
            }
        }

        private mutating func unary() -> Operand? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 50 else { return nil }
            if consume("-") { return unary().map { Operand(value: -$0.value, isPercent: $0.isPercent) } }
            if consume("+") { return unary() }
            return power()
        }

        /// Right-associative, and binds tighter than a leading minus: -2^2 is -4.
        private mutating func power() -> Operand? {
            guard let base = primary() else { return nil }
            guard consume("^") else { return base }
            guard let exponent = unary() else { return nil }
            operationCount += 1
            let result = pow(base.value, exponent.value)
            return result.isFinite ? Operand(value: result) : nil
        }

        private mutating func primary() -> Operand? {
            var operand: Operand
            if consume("(") {
                guard let inner = expression(), consume(")") else { return nil }
                operand = Operand(value: inner.value)
            } else {
                skipSpaces()
                let start = index
                while index < characters.count, characters[index].isASCII,
                      characters[index].isNumber || characters[index] == "." {
                    index += 1
                }
                guard start < index, let value = Double(String(characters[start..<index])) else { return nil }
                operand = Operand(value: value)
            }
            if consume("%") { operand = Operand(value: operand.value / 100, isPercent: true) }
            return operand
        }
    }

    // MARK: Units

    private struct Unit {
        let dimension: String
        /// Size of one unit in the dimension's base unit.
        let factor: Double
        /// Added before scaling (temperature scales that don't start at zero).
        let offset: Double
        let label: String
    }

    private static let units: [String: Unit] = {
        var result: [String: Unit] = [:]
        func add(_ aliases: [String], _ dimension: String, _ factor: Double, _ label: String, offset: Double = 0) {
            for alias in aliases { result[alias] = Unit(dimension: dimension, factor: factor, offset: offset, label: label) }
        }
        add(["m", "meter", "meters", "metre", "metres"], "length", 1, "m")
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], "length", 1000, "km")
        add(["cm", "centimeter", "centimeters"], "length", 0.01, "cm")
        add(["mm", "millimeter", "millimeters"], "length", 0.001, "mm")
        add(["mi", "mile", "miles"], "length", 1609.344, "mi")
        add(["yd", "yard", "yards"], "length", 0.9144, "yd")
        add(["ft", "foot", "feet"], "length", 0.3048, "ft")
        add(["in", "inch", "inches"], "length", 0.0254, "in")
        add(["nmi", "nauticalmile", "nauticalmiles"], "length", 1852, "nmi")

        add(["kg", "kilogram", "kilograms", "kilo", "kilos"], "mass", 1, "kg")
        add(["g", "gram", "grams"], "mass", 0.001, "g")
        add(["mg", "milligram", "milligrams"], "mass", 0.000001, "mg")
        add(["t", "tonne", "tonnes"], "mass", 1000, "t")
        add(["lb", "lbs", "pound", "pounds"], "mass", 0.45359237, "lb")
        add(["oz", "ounce", "ounces"], "mass", 0.028349523125, "oz")
        add(["st", "stone"], "mass", 6.35029318, "st")

        add(["l", "liter", "liters", "litre", "litres"], "volume", 1, "L")
        add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], "volume", 0.001, "mL")
        add(["gal", "gallon", "gallons"], "volume", 3.785411784, "US gal")
        add(["qt", "quart", "quarts"], "volume", 0.946352946, "US qt")
        add(["pt", "pint", "pints"], "volume", 0.473176473, "US pt")
        add(["cup", "cups"], "volume", 0.2365882365, "US cups")
        add(["floz"], "volume", 0.0295735295625, "US fl oz")
        add(["tbsp", "tablespoon", "tablespoons"], "volume", 0.01478676478125, "tbsp")
        add(["tsp", "teaspoon", "teaspoons"], "volume", 0.00492892159375, "tsp")

        add(["sqm", "m2"], "area", 1, "m²")
        add(["sqkm", "km2"], "area", 1_000_000, "km²")
        add(["sqft", "ft2"], "area", 0.09290304, "ft²")
        add(["sqmi", "mi2"], "area", 2_589_988.110336, "mi²")
        add(["acre", "acres"], "area", 4046.8564224, "acres")
        add(["ha", "hectare", "hectares"], "area", 10_000, "ha")

        add(["mph"], "speed", 0.44704, "mph")
        add(["kph", "kmh", "kmph"], "speed", 1000.0 / 3600, "km/h")
        add(["mps", "ms"], "speed", 1, "m/s")
        add(["kn", "kt", "knot", "knots"], "speed", 1852.0 / 3600, "kn")

        add(["s", "sec", "secs", "second", "seconds"], "time", 1, "s")
        add(["min", "mins", "minute", "minutes"], "time", 60, "min")
        add(["h", "hr", "hrs", "hour", "hours"], "time", 3600, "h")
        add(["d", "day", "days"], "time", 86400, "days")
        add(["wk", "week", "weeks"], "time", 604_800, "weeks")

        add(["b", "byte", "bytes"], "data", 1, "B")
        add(["kb", "kilobyte", "kilobytes"], "data", 1000, "KB")
        add(["mb", "megabyte", "megabytes"], "data", 1_000_000, "MB")
        add(["gb", "gigabyte", "gigabytes"], "data", 1_000_000_000, "GB")
        add(["tb", "terabyte", "terabytes"], "data", 1_000_000_000_000, "TB")
        add(["kib"], "data", 1024, "KiB")
        add(["mib"], "data", 1_048_576, "MiB")
        add(["gib"], "data", 1_073_741_824, "GiB")
        add(["tib"], "data", 1_099_511_627_776, "TiB")

        add(["c", "celsius", "degc"], "temperature", 1, "°C")
        add(["f", "fahrenheit", "degf"], "temperature", 5.0 / 9, "°F", offset: -32)
        add(["k", "kelvin"], "temperature", 1, "K", offset: -273.15)
        return result
    }()

    private static let conversionRegex = try! NSRegularExpression(
        pattern: #"^(-?(?:\d+(?:,\d{3})*|\d*)(?:\.\d+)?)\s*°?\s*([a-z][a-z0-9]*)\s+(?:to|in|into|as)\s+°?\s*([a-z][a-z0-9]*)$"#
    )

    private static func conversion(_ query: String) -> Answer? {
        let ns = query as NSString
        guard let match = conversionRegex.firstMatch(in: query, range: NSRange(location: 0, length: ns.length)),
              let amount = Double(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")),
              let from = units[ns.substring(with: match.range(at: 2))],
              let to = units[ns.substring(with: match.range(at: 3))],
              from.dimension == to.dimension else { return nil }
        let base = (amount + from.offset) * from.factor
        let converted = base / to.factor - to.offset
        guard converted.isFinite else { return nil }
        return Answer(
            result: "\(format(converted, grouped: true)) \(to.label)",
            detail: "\(format(amount, grouped: true)) \(from.label) →",
            copyText: format(converted, grouped: false)
        )
    }

    // MARK: Time zones

    /// Abbreviations a person would type. The generic ones (PT, ET, …) follow
    /// daylight saving; the specific ones (PST, EDT, …) are fixed offsets.
    private static func zone(abbreviation: String) -> TimeZone? {
        switch abbreviation {
        case "pt": TimeZone(identifier: "America/Los_Angeles")
        case "et": TimeZone(identifier: "America/New_York")
        case "ct": TimeZone(identifier: "America/Chicago")
        case "mt": TimeZone(identifier: "America/Denver")
        case "pst": TimeZone(secondsFromGMT: -8 * 3600)
        case "pdt": TimeZone(secondsFromGMT: -7 * 3600)
        case "mst": TimeZone(secondsFromGMT: -7 * 3600)
        case "mdt": TimeZone(secondsFromGMT: -6 * 3600)
        case "cst": TimeZone(secondsFromGMT: -6 * 3600)
        case "cdt": TimeZone(secondsFromGMT: -5 * 3600)
        case "est": TimeZone(secondsFromGMT: -5 * 3600)
        case "edt": TimeZone(secondsFromGMT: -4 * 3600)
        case "utc", "gmt": TimeZone(secondsFromGMT: 0)
        case "bst": TimeZone(secondsFromGMT: 3600)
        case "cet": TimeZone(secondsFromGMT: 3600)
        case "cest": TimeZone(secondsFromGMT: 2 * 3600)
        case "eet": TimeZone(secondsFromGMT: 2 * 3600)
        case "eest": TimeZone(secondsFromGMT: 3 * 3600)
        case "jst": TimeZone(secondsFromGMT: 9 * 3600)
        case "kst": TimeZone(secondsFromGMT: 9 * 3600)
        case "hkt": TimeZone(secondsFromGMT: 8 * 3600)
        case "sgt": TimeZone(secondsFromGMT: 8 * 3600)
        case "aest": TimeZone(secondsFromGMT: 10 * 3600)
        case "aedt": TimeZone(secondsFromGMT: 11 * 3600)
        default: nil
        }
    }

    private static let cityAliases = [
        "nyc": "America/New_York", "la": "America/Los_Angeles", "sf": "America/Los_Angeles",
        "uk": "Europe/London", "india": "Asia/Kolkata", "ist": "Asia/Kolkata",
    ]

    /// "tokyo", "new york", "los angeles" → the zone with that city name.
    private static let citiesToZones: [String: String] = {
        var result: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard let city = identifier.split(separator: "/").last else { continue }
            result[city.replacingOccurrences(of: "_", with: " ").lowercased()] = identifier
        }
        return result.merging(cityAliases) { _, alias in alias }
    }()

    /// City names are only understood where a conversion is clearly asked for,
    /// so "9:00 paris" on its own stays an ordinary search.
    private static func zone(named name: String, allowsCities: Bool) -> (zone: TimeZone, label: String)? {
        if let zone = zone(abbreviation: name) { return (zone, name.uppercased()) }
        guard allowsCities, let identifier = citiesToZones[name], let zone = TimeZone(identifier: identifier) else { return nil }
        if cityAliases[name] != nil { return (zone, name.uppercased()) }
        let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
        return (zone, city ?? name.capitalized)
    }

    private static let timeRegex = try! NSRegularExpression(
        pattern: #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?\s+([a-z][a-z ]*?)(?:\s+(?:to|in|into)\s+([a-z][a-z ]*))?$"#
    )

    /// "3:30pm pt", "15:00 utc to est", "9 am et in tokyo". A time with no
    /// zone isn't a question this answers, and a bare "8:30" with no am/pm is
    /// read as a 24-hour clock (the detail line shows how it was read).
    private static func time(_ query: String, now: Date, localZone: TimeZone) -> Answer? {
        let ns = query as NSString
        guard let match = timeRegex.firstMatch(in: query, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let targetName = group(5)?.trimmingCharacters(in: .whitespaces)
        guard let hourText = group(1), var hour = Int(hourText),
              let sourceName = group(4),
              let source = zone(named: sourceName.trimmingCharacters(in: .whitespaces), allowsCities: targetName != nil) else { return nil }
        let minute = group(2).flatMap { Int($0) } ?? 0
        let meridiem = group(3)?.first
        // "9 pt" is just words; a time needs a colon or am/pm.
        guard group(2) != nil || meridiem != nil, minute <= 59 else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "p" ? 12 : 0)
        } else {
            guard hour <= 23 else { return nil }
        }

        let destination: (zone: TimeZone, label: String)
        if let targetName {
            guard let target = zone(named: targetName, allowsCities: true) else { return nil }
            destination = target
        } else {
            destination = (localZone, "your time")
        }

        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = source.zone
        var components = sourceCalendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        guard let date = sourceCalendar.date(from: components),
              // A time skipped by a clock change comes back shifted: no such time.
              sourceCalendar.component(.hour, from: date) == hour,
              sourceCalendar.component(.minute, from: date) == minute else { return nil }

        var targetCalendar = Calendar(identifier: .gregorian)
        targetCalendar.timeZone = destination.zone
        let clock = DateFormatter()
        clock.timeZone = destination.zone
        clock.locale = .current
        clock.dateStyle = .none
        clock.timeStyle = .short
        var result = clock.string(from: date)
        let dayOffset = targetCalendar.dateComponents(
            [.day],
            from: targetCalendar.startOfDay(for: now),
            to: targetCalendar.startOfDay(for: date)
        ).day ?? 0
        switch dayOffset {
        case 0: break
        case 1: result += " tomorrow"
        case -1: result += " yesterday"
        default:
            let day = DateFormatter()
            day.timeZone = destination.zone
            day.setLocalizedDateFormatFromTemplate("EEEMMMd")
            result += ", " + day.string(from: date)
        }

        let zoneName = destination.zone.abbreviation(for: date) ?? destination.zone.identifier
        let shown = destination.label == "your time" ? "your time (\(zoneName))" : destination.label
        let sourceClock = String(format: "%d:%02d", meridiem == nil ? hour : (hour % 12 == 0 ? 12 : hour % 12), minute)
        let suffix = meridiem.map { $0 == "p" ? " PM" : " AM" } ?? ""
        return Answer(
            result: result,
            detail: "\(sourceClock)\(suffix) \(source.label) in \(shown)",
            copyText: result
        )
    }
}
