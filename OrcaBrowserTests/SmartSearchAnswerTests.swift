import Foundation
import Testing
@testable import OrcaBrowser

struct SmartSearchAnswerTests {
    /// Thursday 2026-11-05 12:00 UTC, after daylight saving ended in the US.
    private let now = Date(timeIntervalSince1970: 1_793_880_000)
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func answer(_ query: String) -> SmartSearchAnswer.Answer? {
        SmartSearchAnswer.evaluate(query, now: now, localZone: newYork)
    }

    /// Clock times use a narrow no-break space before "PM" on recent iOS.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // MARK: Calculator

    @Test(arguments: [
        ("24 * 7", "168"),
        ("24*7", "168"),
        ("2+3*4", "14"),
        ("(2+3)*4", "20"),
        ("10/4", "2.5"),
        ("1/3", "0.333333333333333"),
        ("0.1+0.2", "0.3"),
        ("-2^2", "-4"),
        ("2^3^2", "512"),
        ("2^-1", "0.5"),
        ("3 x 4", "12"),
        ("6 ÷ 3", "2"),
        ("1000 - 250", "750"),
        ("100 + 10%", "110"),
        ("100 - 10%", "90"),
        ("50% of 80", "40"),
        ("5 * 10%", "0.5"),
        ("1,000 + 1", "1001"),
        ("1e5+1", "100001"),
    ])
    func calculates(query: String, copied: String) throws {
        let result = try #require(answer(query))
        #expect(result.copyText == copied)
        #expect(result.detail == "Calculation")
    }

    @Test(arguments: [
        "555-1234", "94103-1234", "11/5/2024", "2024-11-05", "555-12-3456",
        "+1", "-5", "5", "100%", "50%", "(5)", "10 % 3", "10%3",
        "1/0", "2+", "(1+2", "1+2)", "0x10", "2024", "3.14", "1.2.3",
        "best pizza", "iphone 15 pro", "7-eleven", "24 hour fitness", "",
    ])
    func ordinarySearchesAreLeftAlone(query: String) {
        #expect(answer(query) == nil)
    }

    @Test func hugeResultsUseScientificNotation() throws {
        #expect(try #require(answer("10^20")).copyText == "1E20")
        #expect(answer("10^400") == nil)
    }

    @Test func absurdNestingDoesNotCrash() {
        #expect(answer(String(repeating: "(", count: 60) + "1+1" + String(repeating: ")", count: 60)) == nil)
        #expect(answer(String(repeating: "-", count: 150) + "1+1") == nil)
    }

    @Test func zeroIsNeverNegative() throws {
        #expect(try #require(answer("0 * -1")).copyText == "0")
    }

    // MARK: Units

    @Test(arguments: [
        ("1 mi to km", "1.609344 km"),
        ("5 km in mi", "3.10685596 mi"),
        ("100 c to f", "212 °F"),
        ("32 f to c", "0 °C"),
        ("0 c to k", "273.15 K"),
        ("-40 c to f", "-40 °F"),
        ("1 gb to mb", "1000 MB"),
        ("1 gib to mib", "1024 MiB"),
        ("60 mph to kph", "96.56064 km/h"),
        ("90 min to h", "1.5 h"),
        ("2 lbs to kg", "0.90718474 kg"),
        ("1,000 m to km", "1 km"),
        ("5km to mi", "3.10685596 mi"),
        ("1 mm to mi", "0.0000006213711922 mi"),
    ])
    func converts(query: String, expected: String) throws {
        let result = try #require(answer(query))
        // The grouping separator depends on the device's region.
        let digits = result.result.filter { $0 != "," && $0 != " " && $0 != "\u{202F}" && $0 != "\u{00A0}" }
        #expect(digits == expected.filter { $0 != " " })
    }

    @Test(arguments: ["1 kg to km", "1 foo to bar", "4k", "5g", "10 m", "5 in", "1st", "5 ha", "0 k", "to km", "5 c to z", "1" + String(repeating: "0", count: 400) + " m to km"])
    func nonsenseConversionsAreLeftAlone(query: String) {
        #expect(answer(query) == nil)
    }

    @Test(arguments: [
        ("2mi", "3.218688 km"),
        ("2 mi", "3.218688 km"),
        ("10 km", "6.21371192 mi"),
        ("100 c", "212 °F"),
        ("100 f", "37.77777778 °C"),
        ("150 lbs", "68.0388555 kg"),
        ("12 oz", "340.1942775 g"),
        ("60 mph", "96.56064 km/h"),
        ("90 min", "1.5 h"),
        ("1 gb", "1000 MB"),
        ("2 mi to", "3.218688 km"),
        ("1 m to", "3.2808399 ft"),
        ("5 c to", "41 °F"),
    ])
    func aloneANumberAndUnitConvertToTheLikelyOne(query: String, expected: String) throws {
        let result = try #require(answer(query))
        // The grouping separator depends on the device's region.
        #expect(plain(result.result).replacingOccurrences(of: ",", with: "") == expected)
    }

    @Test func bitsAndBytesAreToldApartByCase() throws {
        #expect(try #require(answer("1 MB to Mb")).result == "8 Mb")
        #expect(try #require(answer("8 Mb to MB")).result == "1 MB")
        #expect(try #require(answer("100 Mb to gb")).result == "0.0125 GB")
        #expect(try #require(answer("1 gb to mb")).result.replacingOccurrences(of: ",", with: "") == "1000 MB")
        #expect(try #require(answer("16 bits to bytes")).result == "2 B")
        #expect(try #require(answer("100 Mb")).result == "12.5 MB")
        #expect(try #require(answer("100 mb")).result == "0.1 GB")
    }

    @Test func aPartlyTypedTargetPicksTheLikelyUnit() throws {
        #expect(try #require(answer("2 mi to k")).result == "3.218688 km")
        #expect(try #require(answer("2 kg to l")).result.hasSuffix("lb"))
        #expect(try #require(answer("5 ft to c")).result == "152.4 cm")
        #expect(answer("5 ft to z") == nil)
    }

    // MARK: Time zones

    @Test func convertsToTheLocalZone() throws {
        // 9 AM PST on Nov 5 is noon in New York (EST).
        let result = try #require(answer("9am pst"))
        #expect(plain(result.copyText) == "12:00 PM")
        #expect(result.detail.hasPrefix("9:00 AM PST (Los Angeles) in your time (New York)"))
    }

    @Test func abbreviationsNameACityThatKeepsThatTime() throws {
        #expect(try #require(answer("time in pst")).detail == "Time in PST (Los Angeles)")
        #expect(try #require(answer("time in cdt")).detail == "Time in CDT (Chicago)")
        #expect(try #require(answer("time in jst")).detail == "Time in JST (Tokyo)")
        #expect(try #require(answer("time in cest")).detail == "Time in CEST (Paris)")
        #expect(try #require(answer("time in utc")).detail == "Time in UTC")
    }

    @Test func yourTimeNamesYourCity() throws {
        #expect(try #require(answer("9pm paris")).detail.hasSuffix("in your time (New York)"))
        #expect(try #require(answer("9am to tokyo")).detail.hasPrefix("9:00 AM your time (New York) in Tokyo"))
    }

    @Test func aZoneWithoutACityUsesItsOwnName() throws {
        let offsetOnly = try #require(TimeZone(identifier: "Etc/GMT-3"))
        let result = SmartSearchAnswer.evaluate("9pm paris", now: now, localZone: offsetOnly)
        #expect(try #require(result).detail.hasSuffix("in your time (GMT+3)"))
    }

    @Test func usZonesFollowDaylightSavingWhicheverFormIsTyped() throws {
        // Nov 5: PT is PST (UTC-8), ET is EST (UTC-5). "PDT" means Pacific time too.
        for query in ["9:00 am pt to et", "9:00 am pst to est", "9:00 am pdt to edt", "9:00 am pdt to et"] {
            #expect(plain(try #require(answer(query)).copyText) == "12:00 PM", "\(query)")
        }
        // Summer: the same words give the summer offsets.
        let july = try #require(ISO8601DateFormatter().date(from: "2026-07-01T12:00:00Z"))
        let summer = try #require(SmartSearchAnswer.evaluate("9am pst to est", now: july, localZone: newYork))
        #expect(plain(summer.copyText) == "12:00 PM")
        let central = try #require(SmartSearchAnswer.evaluate("9am cst to utc", now: july, localZone: newYork))
        #expect(plain(central.copyText) == "2:00 PM")
    }

    @Test func twentyFourHourTimesNeedNoMeridiem() throws {
        #expect(plain(try #require(answer("15:30 utc")).copyText) == "10:30 AM")
        // Noon is unambiguous as 12:30.
        #expect(plain(try #require(answer("12:30 utc")).copyText) == "7:30 AM")
    }

    @Test func daysAreNamedWhenTheyDiffer() throws {
        #expect(plain(try #require(answer("11pm pt to et")).copyText) == "2:00 AM tomorrow")
        #expect(plain(try #require(answer("1am et to pt")).copyText) == "10:00 PM yesterday")
    }

    @Test func citiesAndCountriesConvert() throws {
        #expect(plain(try #require(answer("9am tokyo to new york")).copyText) == "7:00 PM yesterday")
        // 9 PM in Paris (CET, UTC+1) is 3 PM in New York.
        #expect(plain(try #require(answer("9pm Paris")).copyText) == "3:00 PM")
        #expect(plain(try #require(answer("9pm india")).copyText) == "10:30 AM")
        #expect(plain(try #require(answer("9:00 paris")).copyText) == "3:00 AM")
        #expect(plain(try #require(answer("9am in tokyo")).copyText) == "11:00 PM")
    }

    @Test func currentTimeInAPlace() throws {
        // Noon UTC.
        for query in ["time in sf", "time sf", "time at sf", "sf time", "what time is it in SF", "current time in San Francisco"] {
            let result = try #require(answer(query), "\(query)")
            #expect(plain(result.copyText) == "4:00 AM", "\(query)")
        }
        #expect(plain(try #require(answer("what's the time in London?")).copyText) == "12:00 PM")
        #expect(plain(try #require(answer("time in the uk")).copyText) == "12:00 PM")
        #expect(plain(try #require(answer("tokyo time")).copyText) == "9:00 PM")
        #expect(try #require(answer("time in japan")).detail == "Time in Japan")
        #expect(try #require(answer("time in usa")).detail == "Time in USA (New York)")
        #expect(answer("time in nowhereland") == nil)
        #expect(answer("lunch time") == nil)
    }

    @Test func theFieldCanTakeTheAnswerWithItsUnit() throws {
        #expect(try #require(answer("24*7")).fieldText == "168")
        #expect(try #require(answer("2 mi")).fieldText == "3.218688 km")
        #expect(plain(try #require(answer("time sf")).fieldText) == "4:00 AM")
    }

    @Test(arguments: [
        ("1 l to gal", "l"),
        ("1 l to qt", "l"),
        ("1 l to pt", "l"),
        ("1 l to cups", "l"),
        ("1 l to floz", "l"),
        ("1 sqm to sqft", "sqm"),
        ("1 sqkm to sqmi", "sqkm"),
        ("1 sqft to sqm", "sqft"),
        ("1 sqmi to sqkm", "sqmi"),
        ("1 c to f", "c"),
        ("1 gb to kib", "gb"),
        ("1 mg to t", "mg"),
    ])
    func insertedConversionsCanBeConvertedAgain(query: String, originalUnit: String) throws {
        let original = try #require(answer(query))
        let convertedBack = try #require(answer(original.fieldText + " to " + originalUnit))
        let amount = try #require(Double(convertedBack.copyText))
        #expect(abs(amount - 1) < 0.000001)
    }

    @Test func largeResultsKeepTheirDigitsWhenCopiedOrInserted() throws {
        let result = try #require(answer("123456789012345 * 10"))
        #expect(result.copyText == "1.23456789012345E15")
        #expect(result.fieldText == result.copyText)
        // The short form is only for reading.
        #expect(result.result.filter { $0.isNumber }.count <= 9)
        let continued = try #require(answer(result.fieldText + " + 1000"))
        #expect(continued.copyText == "1.23456789012445E15")
        // A nonzero sixteenth digit survives, in the copy and in a follow-up sum.
        let sixteen = try #require(answer("1000000000000001 * 1"))
        #expect(sixteen.copyText == "1.000000000000001E15")
        #expect(try #require(answer(sixteen.fieldText + " + 1")).copyText == "1.000000000000002E15")
        // Below 1e15 an integer stays exact.
        #expect(try #require(answer("999999999999999 + 0")).copyText == "999999999999999")
    }

    @Test func fractionsKeepTheirDigitsWhenCopiedOrInserted() throws {
        let third = try #require(answer("1/3"))
        #expect(third.result.filter(\.isNumber).count <= 11)
        #expect(third.copyText == "0.333333333333333")
        #expect(third.fieldText == third.copyText)
        #expect(try #require(answer("10/3")).copyText == "3.33333333333333")
        // Binary noise is still hidden.
        #expect(try #require(answer("0.1 + 0.2")).copyText == "0.3")
        // Inserting a result and carrying on stays within a digit of the one-sum answer.
        let carried = try #require(answer(third.fieldText + " * 3"))
        #expect(abs(try #require(Double(carried.copyText)) - 1) < 1e-14)
        let converted = try #require(answer("1 mm to mi"))
        #expect(converted.copyText == "0.000000621371192237334")
    }

    @Test func scientificResultsCanContinueCalculations() throws {
        for query in ["1000000000000000 * 2", "0.00000000001 / 2"] {
            let original = try #require(answer(query))
            let continued = try #require(answer(original.fieldText + " * 2"))
            let originalValue = try #require(Double(original.copyText))
            #expect(Double(continued.copyText) == originalValue * 2)
        }
        #expect(try #require(answer("1e+3 + 2E-1")).copyText == "1000.2")
        #expect(try #require(answer("1e3 mi to km")).copyText == "1609.344")
    }

    @Test(arguments: ["1e + 2", "1e- * 2", "1e2e3 + 2", "e3 + 2", "1e999 * 2", "1e999 mi to km", "2E15"])
    func invalidOrStandaloneScientificNumbersStaySearches(query: String) {
        #expect(answer(query) == nil)
    }

    @Test func currentTimeUsesTheLatestEvaluationDate() throws {
        let first = try #require(answer("time sf"))
        let nextMinute = try #require(SmartSearchAnswer.evaluate("time sf", now: now.addingTimeInterval(60), localZone: newYork))
        #expect(first.copyText != nextMinute.copyText)
        #expect(plain(nextMinute.copyText) == "4:01 AM")
    }

    @Test func everyListedPlaceHasARealTimeZone() {
        for (name, identifier) in SmartSearchAnswer.countries.merging(SmartSearchAnswer.extraCities, uniquingKeysWith: { $1 }) {
            #expect(TimeZone(identifier: identifier) != nil, "\(name) → \(identifier)")
        }
    }

    @Test(arguments: ["25:00 pt", "13pm pt", "0am pt", "9:61 pt", "9 paris", "pt", "9am", "9am foo", "9am pt to foo", "1 mile in paris"])
    func invalidTimesAreLeftAlone(query: String) {
        #expect(answer(query) == nil)
    }

    @Test func skippedTimesDuringSpringForwardAreRejected() {
        // 2026-03-08 10:00 UTC, in the US. 2:30 AM never happened in Los Angeles.
        let springForward = Date(timeIntervalSince1970: 1_772_964_000)
        #expect(SmartSearchAnswer.evaluate("2:30 am pt", now: springForward, localZone: newYork) == nil)
        #expect(SmartSearchAnswer.evaluate("3:30 am pt", now: springForward, localZone: newYork) != nil)
    }

    @Test func repeatedTimesShowBothOccurrences() throws {
        let fallBack = try #require(ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z"))
        let result = try #require(SmartSearchAnswer.evaluate("1:30am pt to utc", now: fallBack, localZone: newYork))
        #expect(plain(result.copyText) == "8:30 AM (UTC+00:00) or 9:30 AM (UTC+00:00)")
        #expect(result.detail.contains("occurs twice during clock change"))
        #expect(result.fieldText == result.copyText)
    }

    @Test func repeatedDestinationClocksHaveDistinctOffsets() throws {
        let fallBack = try #require(ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z"))
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let result = try #require(SmartSearchAnswer.evaluate("1:30am pt", now: fallBack, localZone: pacific))
        #expect(plain(result.copyText) == "1:30 AM (UTC−07:00) or 1:30 AM (UTC−08:00)")
        #expect(result.detail.hasPrefix("1:30 AM PT (Los Angeles) in your time (Los Angeles) ·"))
    }

    @Test func halfHourClockChangesShowBothOccurrences() throws {
        let fallBack = try #require(ISO8601DateFormatter().date(from: "2026-04-05T12:00:00Z"))
        let result = try #require(SmartSearchAnswer.evaluate("1:45am lord howe to utc", now: fallBack, localZone: newYork))
        #expect(plain(result.copyText) == "2:45 PM yesterday (UTC+00:00) or 3:15 PM yesterday (UTC+00:00)")
        #expect(result.detail.contains("2026-04-05 → 2026-04-04"))
    }

    @Test func chinaStandardTimeIsStillSelectedByCountryName() throws {
        #expect(plain(try #require(answer("9am china to utc")).copyText) == "1:00 AM")
    }

    @Test func dateCrossingsStayVisibleWhenZonesAlreadyHaveDifferentDates() throws {
        let midnightBoundary = try #require(ISO8601DateFormatter().date(from: "2026-11-06T06:00:00Z"))
        let eastbound = try #require(SmartSearchAnswer.evaluate("11:30pm pt to et", now: midnightBoundary, localZone: newYork))
        #expect(plain(eastbound.copyText) == "2:30 AM")
        #expect(eastbound.detail.contains("2026-11-05 → 2026-11-06"))
        let westbound = try #require(SmartSearchAnswer.evaluate("1am et to pt", now: midnightBoundary, localZone: newYork))
        #expect(plain(westbound.copyText) == "10:00 PM")
        #expect(westbound.detail.contains("2026-11-06 → 2026-11-05"))
        #expect(try #require(answer("9am pt to et")).detail == "9:00 AM PT (Los Angeles) in ET (New York)")
    }
}
