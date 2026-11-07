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
        /// What replaces the search field's text: the copied value, with its unit.
        let fieldText: String
    }

    static func evaluate(
        _ raw: String,
        now: Date = Date(),
        localZone: TimeZone = .current,
        usesMetric: Bool = Locale.current.measurementSystem == .metric
    ) -> Answer? {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 200 else { return nil }
        return time(query.lowercased(), now: now, localZone: localZone)
            ?? conversion(query.lowercased(), usesMetric: usesMetric)
            ?? calculation(query)
    }

    // MARK: Numbers

    /// Fifteen significant digits hides binary rounding noise (0.1 + 0.2).
    /// Very large and very small values switch to scientific notation rather
    /// than showing a wall of digits or rounding to zero.
    static func format(_ number: Double, grouped: Bool) -> String {
        guard number.isFinite else { return "" }
        // Whole numbers are exact already; rounding them to 15 digits would
        // change a 16-digit integer.
        let cleaned = number == number.rounded() ? number : Double(String(format: "%.15g", number)) ?? number
        if cleaned == 0 { return "0" }
        let magnitude = abs(cleaned)
        let style = FloatingPointFormatStyle<Double>(locale: grouped ? .current : Locale(identifier: "en_US_POSIX"))
            .grouping(grouped ? .automatic : .never)
        if magnitude >= 1e15 || magnitude < 1e-9 {
            // The screen gets a short form; copying and inserting keep every digit a
            // double holds, so the value can go on into another calculation.
            return style.notation(.scientific).precision(.significantDigits(1...(grouped ? 7 : 17))).format(cleaned)
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

        let allowed = CharacterSet(charactersIn: "0123456789.eE+-*/^()% ")
        guard text.rangeOfCharacter(from: allowed.inverted) == nil,
              text.rangeOfCharacter(from: .decimalDigits) != nil,
              !looksLikeDateOrPhoneNumber(text) else { return nil }
        var parser = ArithmeticParser(Array(text))
        guard let value = parser.parse(), parser.operationCount > 0, value.isFinite else { return nil }
        return Answer(
            result: format(value, grouped: true),
            detail: "Calculation",
            copyText: format(value, grouped: false),
            fieldText: format(value, grouped: false)
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
                if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                    index += 1
                    if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                        index += 1
                    }
                    let exponentStart = index
                    while index < characters.count, characters[index].isASCII, characters[index].isNumber {
                        index += 1
                    }
                    guard index > exponentStart else { return nil }
                }
                guard start < index, let value = Double(String(characters[start..<index])) else { return nil }
                operand = Operand(value: value)
            }
            if consume("%") { operand = Operand(value: operand.value / 100, isPercent: true) }
            return operand
        }
    }


    private struct Unit {
        let dimension: String
        /// Size of one unit in the dimension's base unit.
        let factor: Double
        /// Added before scaling (temperature scales that don't start at zero).
        let offset: Double
        let label: String
        /// Registration order, which ranks partly typed targets: "k" is km.
        let order: Int
    }

    private static let units: [String: Unit] = {
        var result: [String: Unit] = [:]
        func add(_ aliases: [String], _ dimension: String, _ factor: Double, _ label: String, offset: Double = 0) {
            for alias in aliases {
                result[alias] = Unit(dimension: dimension, factor: factor, offset: offset, label: label, order: result.count)
            }
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

        add(["mph", "mi/h"], "speed", 0.44704, "mph")
        add(["kph", "kmh", "kmph", "km/h"], "speed", 1000.0 / 3600, "km/h")
        add(["mps", "m/s"], "speed", 1, "m/s")
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
        for unit in result.values.sorted(by: { $0.order < $1.order }) {
            let alias = unit.label.lowercased()
                .replacingOccurrences(of: "²", with: "2")
                .replacingOccurrences(of: "°", with: "")
                .replacingOccurrences(of: " ", with: "")
            if result[alias] == nil { result[alias] = unit }
        }
        return result
    }()

    private static let unitsByLabel: [String: Unit] = {
        var result: [String: Unit] = [:]
        for unit in units.values where result[unit.label] == nil { result[unit.label] = unit }
        return result
    }()

    /// What a number and a unit alone convert to: "2 mi" is "2 mi to km".
    private static func defaultTarget(for unit: Unit, usesMetric: Bool) -> Unit? {
        let label: String? = switch unit.label {
        case "mi": "km"
        case "km": "mi"
        case "m": "ft"
        case "ft": "m"
        case "in": "cm"
        case "cm": "in"
        case "mm": "in"
        case "yd": "m"
        case "nmi": "km"
        case "kg": "lb"
        case "lb": "kg"
        case "oz": "g"
        case "g": "oz"
        case "mg": "g"
        case "t": "lb"
        case "st": "kg"
        case "L": usesMetric ? "mL" : "US gal"
        case "mL": "US fl oz"
        case "US gal": "L"
        case "US qt": "L"
        case "US pt": "mL"
        case "US cups": "mL"
        case "US fl oz": "mL"
        case "tbsp": "mL"
        case "tsp": "mL"
        case "m²": "ft²"
        case "ft²": "m²"
        case "km²": "mi²"
        case "mi²": "km²"
        case "acres": "ha"
        case "ha": "acres"
        case "mph": "km/h"
        case "km/h": "mph"
        case "m/s": "km/h"
        case "kn": "km/h"
        case "s": "min"
        case "min": "h"
        case "h": "min"
        case "days": "h"
        case "weeks": "days"
        case "B": "KB"
        case "KB": "MB"
        case "MB": "GB"
        case "GB": "MB"
        case "TB": "GB"
        case "KiB": "MiB"
        case "MiB": "GiB"
        case "GiB": "MiB"
        case "TiB": "GiB"
        case "°C": "°F"
        case "°F": "°C"
        case "K": "°C"
        default: nil
        }
        return label.flatMap { unitsByLabel[$0] }
    }

    /// Short or common words that follow a number for other reasons ("5g",
    /// "4k", "10 m" for million, "1 in"). With a target typed they convert;
    /// on their own they stay ordinary searches.
    private static let needsExplicitTarget: Set<String> = ["k", "g", "m", "s", "d", "t", "b", "h", "in", "st", "ha"]

    /// The unit a partly typed target means: an exact name in the same
    /// dimension, otherwise the first common unit that starts with it.
    private static func target(named typed: String, dimension: String) -> Unit? {
        if let exact = units[typed], exact.dimension == dimension { return exact }
        return units
            .filter { $0.key.hasPrefix(typed) && $0.value.dimension == dimension }
            .min { $0.value.order < $1.value.order }?.value
    }

    private static let conversionRegex = try! NSRegularExpression(
        pattern: #"^(-?(?:\d+(?:,\d{3})*|\d*)(?:\.\d+)?(?:e[+-]?\d+)?)\s*°?\s*((?:us\s+)?(?:fl\s+)?[a-z][a-z0-9/²]*)(?:\s+(to|in|into|as)(?:\s+°?\s*((?:us\s+)?(?:fl\s+)?[a-z][a-z0-9/²]*))?)?$"#
    )

    private static func conversion(_ query: String, usesMetric: Bool) -> Answer? {
        let ns = query as NSString
        guard let match = conversionRegex.firstMatch(in: query, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
                .replacingOccurrences(of: "²", with: "2")
                .replacingOccurrences(of: " ", with: "")
        }
        guard let amount = group(1).flatMap({ Double($0.replacingOccurrences(of: ",", with: "")) }),
              let fromName = group(2), let from = units[fromName] else { return nil }
        let to: Unit
        if let targetName = group(4) {
            guard let found = target(named: targetName, dimension: from.dimension) else { return nil }
            to = found
        } else {
            // "2 mi" or "2 mi to": the most likely unit.
            guard group(3) != nil || !needsExplicitTarget.contains(fromName),
                  let found = defaultTarget(for: from, usesMetric: usesMetric) else { return nil }
            to = found
        }
        let base = (amount + from.offset) * from.factor
        let converted = base / to.factor - to.offset
        guard converted.isFinite else { return nil }
        return Answer(
            result: "\(format(converted, grouped: true)) \(to.label)",
            detail: "\(format(amount, grouped: true)) \(from.label) →",
            copyText: format(converted, grouped: false),
            fieldText: "\(format(converted, grouped: false)) \(to.label)"
        )
    }

    // MARK: Time zones

    /// Abbreviations a person would type. The US ones follow daylight saving
    /// whichever form is typed: "PST" or "PDT" almost always means "Pacific
    /// time right now", so both read as PT, and likewise for ET, CT and MT.
    private static func zone(abbreviation: String) -> TimeZone? {
        switch abbreviation {
        case "pt", "pst", "pdt": TimeZone(identifier: "America/Los_Angeles")
        case "et", "est", "edt": TimeZone(identifier: "America/New_York")
        case "ct", "cst", "cdt": TimeZone(identifier: "America/Chicago")
        case "mt", "mst", "mdt": TimeZone(identifier: "America/Denver")
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

    /// Where a fixed-offset abbreviation is kept; the US ones name their
    /// city through the zone they follow.
    private static let abbreviationCities = [
        "bst": "London", "cet": "Paris", "cest": "Paris", "eet": "Athens", "eest": "Athens",
        "jst": "Tokyo", "kst": "Seoul", "hkt": "Hong Kong", "sgt": "Singapore",
        "aest": "Sydney", "aedt": "Sydney",
    ]

    /// "America/New_York" → "New York". Offset-only zones have no city.
    private static func city(of zone: TimeZone) -> String? {
        let parts = zone.identifier.split(separator: "/")
        guard parts.count >= 2, parts[0] != "Etc", parts[0] != "GMT" else { return nil }
        return parts.last.map { $0.replacingOccurrences(of: "_", with: " ") }
    }

    /// "your time (New York)": the city of the phone's time zone, otherwise
    /// the zone's own abbreviation.
    private static func localLabel(_ zone: TimeZone, at date: Date) -> String {
        let place = city(of: zone) ?? zone.abbreviation(for: date)
        return place.map { "your time (\($0))" } ?? "your time"
    }

    /// Lowercase, no punctuation, single spaces: "St. John's" → "st johns".
    private static func normalizedPlace(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Cities the time zone database has no entry of its own for, and
    /// nicknames, mapped to the zone they keep time by.
    static let extraCities: [String: String] = {
        var result: [String: String] = [:]
        func add(_ identifier: String, _ names: [String]) { for name in names { result[name] = identifier } }
        add("America/Los_Angeles", ["sf", "san francisco", "la", "san jose", "seattle", "portland", "san diego", "las vegas",
                                    "silicon valley", "sacramento", "oakland", "california", "washington state", "nevada"])
        add("America/Phoenix", ["phoenix", "arizona"])
        add("America/Denver", ["salt lake city", "colorado", "utah", "albuquerque", "boulder"])
        add("America/Chicago", ["houston", "dallas", "austin", "san antonio", "new orleans", "minneapolis", "kansas city",
                                "milwaukee", "st louis", "nashville", "texas", "oklahoma city", "memphis"])
        add("America/New_York", ["nyc", "new york city", "boston", "washington", "washington dc", "dc", "philadelphia", "miami",
                                 "atlanta", "orlando", "pittsburgh", "charlotte", "baltimore", "cleveland", "tampa",
                                 "new jersey", "florida", "virginia", "massachusetts", "ohio", "ann arbor", "raleigh"])
        add("Pacific/Honolulu", ["hawaii"])
        add("America/Anchorage", ["alaska"])
        add("America/Toronto", ["montreal", "ottawa", "quebec"])
        add("America/Edmonton", ["calgary", "alberta"])
        add("America/Vancouver", ["british columbia"])
        add("America/Argentina/Buenos_Aires", ["buenos aires"])
        add("America/Sao_Paulo", ["rio", "rio de janeiro", "brasilia"])
        add("America/Mexico_City", ["mexico city"])
        add("Asia/Kolkata", ["india", "mumbai", "delhi", "new delhi", "bangalore", "bengaluru", "hyderabad", "chennai",
                             "calcutta", "pune", "ahmedabad", "ist"])
        add("Asia/Shanghai", ["beijing", "shenzhen", "guangzhou", "chengdu", "wuhan", "tianjin", "chongqing"])
        add("Asia/Tokyo", ["osaka", "kyoto", "yokohama", "nagoya", "sapporo"])
        add("Asia/Ho_Chi_Minh", ["saigon", "hanoi", "vietnam"])
        add("Asia/Dubai", ["abu dhabi", "uae", "united arab emirates", "sharjah"])
        add("Asia/Qatar", ["doha", "qatar"])
        add("Asia/Jerusalem", ["tel aviv", "israel"])
        add("Asia/Tehran", ["iran"])
        add("Asia/Manila", ["philippines"])
        add("Asia/Bangkok", ["thailand"])
        add("Asia/Singapore", ["singapore"])
        add("Europe/London", ["uk", "united kingdom", "england", "britain", "great britain", "scotland", "wales", "edinburgh",
                              "manchester", "glasgow", "birmingham", "liverpool", "cambridge", "oxford"])
        add("Europe/Paris", ["lyon", "marseille", "nice"])
        add("Europe/Berlin", ["munich", "frankfurt", "hamburg", "cologne", "stuttgart", "dusseldorf", "germany"])
        add("Europe/Madrid", ["barcelona", "valencia", "seville", "spain"])
        add("Europe/Rome", ["milan", "venice", "florence", "naples", "turin", "italy"])
        add("Europe/Zurich", ["geneva", "basel", "switzerland"])
        add("Europe/Amsterdam", ["rotterdam", "netherlands", "holland", "the hague"])
        add("Europe/Brussels", ["belgium"])
        add("Europe/Kyiv", ["kiev", "kyiv", "ukraine"])
        add("Europe/Moscow", ["saint petersburg", "st petersburg", "russia"])
        add("Europe/Istanbul", ["turkey", "turkiye", "ankara"])
        add("Africa/Johannesburg", ["cape town", "pretoria", "south africa", "durban"])
        add("Australia/Sydney", ["canberra", "australia"])
        add("Pacific/Auckland", ["wellington", "new zealand", "nz"])
        add("Asia/Seoul", ["south korea", "korea", "busan"])
        add("Asia/Hong_Kong", ["hk", "hong kong"])
        add("Asia/Kuala_Lumpur", ["malaysia"])
        add("Asia/Taipei", ["taiwan"])
        return result
    }()

    /// Countries (and a few regions) that keep a single time, or where one
    /// city stands for the country; the multi-zone ones are listed below.
    static let countries: [String: String] = [
        "usa": "America/New_York", "us": "America/New_York", "united states": "America/New_York",
        "united states of america": "America/New_York", "america": "America/New_York",
        "canada": "America/Toronto", "mexico": "America/Mexico_City", "brazil": "America/Sao_Paulo",
        "argentina": "America/Argentina/Buenos_Aires", "chile": "America/Santiago", "colombia": "America/Bogota",
        "peru": "America/Lima", "venezuela": "America/Caracas", "cuba": "America/Havana",
        "ecuador": "America/Guayaquil", "bolivia": "America/La_Paz", "uruguay": "America/Montevideo",
        "paraguay": "America/Asuncion", "panama": "America/Panama", "costa rica": "America/Costa_Rica",
        "guatemala": "America/Guatemala", "jamaica": "America/Jamaica", "puerto rico": "America/Puerto_Rico",
        "dominican republic": "America/Santo_Domingo", "iceland": "Atlantic/Reykjavik",
        "ireland": "Europe/Dublin", "portugal": "Europe/Lisbon", "france": "Europe/Paris",
        "austria": "Europe/Vienna", "sweden": "Europe/Stockholm", "norway": "Europe/Oslo",
        "denmark": "Europe/Copenhagen", "finland": "Europe/Helsinki", "poland": "Europe/Warsaw",
        "czechia": "Europe/Prague", "czech republic": "Europe/Prague", "slovakia": "Europe/Bratislava",
        "hungary": "Europe/Budapest", "romania": "Europe/Bucharest", "bulgaria": "Europe/Sofia",
        "greece": "Europe/Athens", "serbia": "Europe/Belgrade", "croatia": "Europe/Zagreb",
        "slovenia": "Europe/Ljubljana", "estonia": "Europe/Tallinn", "latvia": "Europe/Riga",
        "lithuania": "Europe/Vilnius", "belarus": "Europe/Minsk", "cyprus": "Asia/Nicosia",
        "malta": "Europe/Malta", "luxembourg": "Europe/Luxembourg", "monaco": "Europe/Monaco",
        "egypt": "Africa/Cairo", "morocco": "Africa/Casablanca", "algeria": "Africa/Algiers",
        "tunisia": "Africa/Tunis", "libya": "Africa/Tripoli", "nigeria": "Africa/Lagos", "ghana": "Africa/Accra",
        "kenya": "Africa/Nairobi", "ethiopia": "Africa/Addis_Ababa", "tanzania": "Africa/Dar_es_Salaam",
        "uganda": "Africa/Kampala", "senegal": "Africa/Dakar", "angola": "Africa/Luanda", "zimbabwe": "Africa/Harare",
        "saudi arabia": "Asia/Riyadh", "saudi": "Asia/Riyadh", "iraq": "Asia/Baghdad", "kuwait": "Asia/Kuwait",
        "jordan": "Asia/Amman", "lebanon": "Asia/Beirut", "syria": "Asia/Damascus", "oman": "Asia/Muscat",
        "bahrain": "Asia/Bahrain", "yemen": "Asia/Aden", "afghanistan": "Asia/Kabul", "pakistan": "Asia/Karachi",
        "bangladesh": "Asia/Dhaka", "sri lanka": "Asia/Colombo", "nepal": "Asia/Kathmandu",
        "myanmar": "Asia/Yangon", "cambodia": "Asia/Phnom_Penh", "laos": "Asia/Vientiane",
        "indonesia": "Asia/Jakarta", "china": "Asia/Shanghai", "japan": "Asia/Tokyo",
        "north korea": "Asia/Pyongyang", "mongolia": "Asia/Ulaanbaatar", "kazakhstan": "Asia/Almaty",
        "uzbekistan": "Asia/Tashkent", "georgia": "Asia/Tbilisi", "armenia": "Asia/Yerevan",
        "azerbaijan": "Asia/Baku", "fiji": "Pacific/Fiji", "papua new guinea": "Pacific/Port_Moresby",
    ]

    /// Countries that span several zones: the name stands for one city, which
    /// the answer names so it isn't mistaken for the whole country.
    private static let multiZoneCountries: Set<String> = [
        "usa", "us", "united states", "united states of america", "america", "canada", "mexico", "brazil",
        "russia", "australia", "indonesia", "kazakhstan", "mongolia", "china",
    ]

    private static let acronyms: Set<String> = ["usa", "us", "uk", "uae", "nz", "hk", "sf", "la", "nyc", "dc", "ist"]

    /// "tokyo", "new york", "los angeles" → the zone with that city name.
    private static let citiesToZones: [String: String] = {
        var result: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            guard let city = identifier.split(separator: "/").last else { continue }
            result[normalizedPlace(String(city))] = identifier
        }
        return result
            .merging(countries) { _, country in country }
            .merging(extraCities) { _, extra in extra }
    }()

    private static func title(_ name: String) -> String {
        name.split(separator: " ").map { word in
            acronyms.contains(String(word)) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    private static func zone(named raw: String) -> (zone: TimeZone, label: String)? {
        var name = normalizedPlace(raw)
        if name.hasPrefix("the ") { name.removeFirst(4) }
        if let zone = zone(abbreviation: name) {
            // "PST" alone doesn't say where; name a city that keeps that time.
            let city = city(of: zone) ?? abbreviationCities[name]
            return (zone, name.uppercased() + (city.map { " (\($0))" } ?? ""))
        }
        guard let identifier = citiesToZones[name], let zone = TimeZone(identifier: identifier) else { return nil }
        var label = title(name)
        if multiZoneCountries.contains(name), let city = identifier.split(separator: "/").last {
            label += " (\(city.replacingOccurrences(of: "_", with: " ")))"
        }
        return (zone, label)
    }

    private static let place = #"[a-z][a-z .'’-]*?"#
    private static let clock = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#
    private static let nowRegex = try! NSRegularExpression(
        pattern: #"^(?:what(?:'s|\s+is)?\s+(?:the\s+)?)?(?:current\s+|local\s+)?time(?:\s+is\s+it)?(?:\s+now)?(?:\s+(?:in|at))?\s+("# + place + #")\??$"#
    )
    private static let placeTimeRegex = try! NSRegularExpression(pattern: "^(" + place + #")\s+time$"#)
    private static let clockRegex = try! NSRegularExpression(
        pattern: "^" + clock + #"\s+("# + place + #")(?:\s+(?:to|in|into)\s+("# + place + #"))?$"#
    )
    private static let clockToPlaceRegex = try! NSRegularExpression(
        pattern: "^" + clock + #"\s+(?:to|in|into)\s+("# + place + ")$"
    )

    private typealias Place = (zone: TimeZone, label: String)

    /// "time in paris", "what time is it in sf", "tokyo time", "9pm paris",
    /// "3:30pm pt to et", "9am in tokyo". A clock time needs a colon or am/pm
    /// ("9 paris" is just words), and a bare "8:30" with no am/pm is read as
    /// a 24-hour clock (the detail line shows how it was read).
    private static func time(_ rawQuery: String, now: Date, localZone: TimeZone) -> Answer? {
        let query = rawQuery.replacingOccurrences(of: "’", with: "'")
        let ns = query as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func group(_ match: NSTextCheckingResult, _ i: Int) -> String? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }

        for regex in [nowRegex, placeTimeRegex] {
            guard let match = regex.firstMatch(in: query, range: whole) else { continue }
            guard let there = group(match, 1).flatMap(zone(named:)) else { return nil }
            let result = describe(now, in: there.zone, relativeTo: now, referenceZone: localZone)
            return Answer(result: result, detail: "Time in \(there.label)", copyText: result, fieldText: result)
        }

        let source: Place?
        let destination: Place
        let match: NSTextCheckingResult
        if let m = clockRegex.firstMatch(in: query, range: whole), let from = group(m, 4).flatMap(zone(named:)) {
            match = m
            source = from
            if let target = group(m, 5) {
                guard let to = zone(named: target) else { return nil }
                destination = to
            } else {
                destination = (localZone, localLabel(localZone, at: now))
            }
        } else if let m = clockToPlaceRegex.firstMatch(in: query, range: whole),
                  let to = group(m, 4).flatMap(zone(named:)) {
            match = m
            source = nil
            destination = to
        } else {
            return nil
        }

        guard var hour = group(match, 1).flatMap({ Int($0) }) else { return nil }
        let minute = group(match, 2).flatMap { Int($0) } ?? 0
        let meridiem = group(match, 3)?.first
        guard group(match, 2) != nil || meridiem != nil, minute <= 59 else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "p" ? 12 : 0)
        } else {
            guard hour <= 23 else { return nil }
        }

        let sourceZone = source?.zone ?? localZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sourceZone
        guard let day = calendar.dateInterval(of: .day, for: now) else { return nil }
        let start = day.start.addingTimeInterval(-1)
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        guard let date = calendar.nextDate(after: start, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first),
              calendar.isDate(date, inSameDayAs: now) else { return nil }

        let firstOffset = sourceZone.secondsFromGMT(for: date)
        let offsets = Set([firstOffset, sourceZone.secondsFromGMT(for: day.start), sourceZone.secondsFromGMT(for: day.end.addingTimeInterval(-1))])
        let dates = offsets.compactMap { offset -> Date? in
            let occurrence = date.addingTimeInterval(TimeInterval(firstOffset - offset))
            guard calendar.isDate(occurrence, inSameDayAs: now),
                  calendar.component(.hour, from: occurrence) == hour,
                  calendar.component(.minute, from: occurrence) == minute,
                  calendar.component(.second, from: occurrence) == 0 else { return nil }
            return occurrence
        }.sorted()
        let result = dates.map { occurrence in
            let clock = describe(occurrence, in: destination.zone, relativeTo: now, referenceZone: destination.zone)
            return dates.count == 1 ? clock : "\(clock) (\(utcOffset(in: destination.zone, at: occurrence)))"
        }.joined(separator: " or ")
        let shownHour = meridiem == nil ? hour : (hour % 12 == 0 ? 12 : hour % 12)
        let shownClock = String(format: "%d:%02d", shownHour, minute) + (meridiem.map { $0 == "p" ? " PM" : " AM" } ?? "")
        let sourceLabel = source?.label ?? localLabel(localZone, at: now)
        var detail = "\(shownClock) \(sourceLabel) in \(destination.label)"
        if dates.count > 1 { detail += " · occurs twice during clock change" }
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        dayFormatter.timeZone = sourceZone
        let sourceDay = dayFormatter.string(from: date)
        dayFormatter.timeZone = destination.zone
        let destinationDays = dates.map { dayFormatter.string(from: $0) }.reduce(into: [String]()) { days, day in
            if !days.contains(day) { days.append(day) }
        }
        if destinationDays.contains(where: { $0 != sourceDay }) {
            detail += " · \(sourceDay) → \(destinationDays.joined(separator: " / "))"
        }
        return Answer(
            result: result,
            detail: detail,
            copyText: result,
            fieldText: result
        )
    }

    private static func utcOffset(in zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date)
        let minutes = abs(seconds) / 60
        return String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", minutes / 60, minutes % 60)
    }

    /// "9:00 PM", with the day when it isn't the reference day there.
    private static func describe(_ date: Date, in zone: TimeZone, relativeTo reference: Date, referenceZone: TimeZone) -> String {
        let clock = DateFormatter()
        clock.timeZone = zone
        clock.locale = .current
        clock.dateStyle = .none
        clock.timeStyle = .short
        func day(_ date: Date, _ zone: TimeZone) -> Int {
            Int(floor((date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))) / 86400))
        }
        let time = clock.string(from: date)
        switch day(date, zone) - day(reference, referenceZone) {
        case 0: return time
        case 1: return time + " tomorrow"
        case -1: return time + " yesterday"
        default:
            let formatter = DateFormatter()
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
            return time + ", " + formatter.string(from: date)
        }
    }
}
