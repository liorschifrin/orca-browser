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
        ("1/3", "0.3333333333"),
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
    ])
    func calculates(query: String, copied: String) throws {
        let result = try #require(answer(query))
        #expect(result.copyText == copied)
        #expect(result.detail == "Calculation")
    }

    @Test(arguments: [
        "555-1234", "94103-1234", "11/5/2024", "2024-11-05", "555-12-3456",
        "+1", "-5", "5", "100%", "50%", "(5)", "10 % 3", "10%3",
        "1/0", "2+", "(1+2", "1+2)", "0x10", "1e5+1", "2024", "3.14", "1.2.3",
        "best pizza", "iphone 15 pro", "7-eleven", "24 hours", "",
    ])
    func ordinarySearchesAreLeftAlone(query: String) {
        #expect(answer(query) == nil)
    }

    @Test func hugeResultsUseScientificNotation() throws {
        #expect(try #require(answer("10^20")).copyText == "1E20")
        #expect(answer("10^400") == nil)
    }

    @Test func absurdNestingDoesNotCrash() {
        #expect(answer(String(repeating: "(", count: 150) + "1" + String(repeating: ")", count: 150)) == nil)
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

    @Test(arguments: ["1 kg to km", "1 foo to bar", "1 m to", "to km", "5 c to", "1" + String(repeating: "0", count: 400) + " m to km"])
    func nonsenseConversionsAreLeftAlone(query: String) {
        #expect(answer(query) == nil)
    }

    // MARK: Time zones

    @Test func convertsToTheLocalZone() throws {
        // 9 AM PST on Nov 5 is noon in New York (EST).
        let result = try #require(answer("9am pst"))
        #expect(plain(result.copyText) == "12:00 PM")
        #expect(result.detail.hasPrefix("9:00 AM PST in your time"))
    }

    @Test func genericZonesFollowDaylightSaving() throws {
        // Nov 5: PT is PST (UTC-8), ET is EST (UTC-5).
        #expect(plain(try #require(answer("9:00 am pt to et")).copyText) == "12:00 PM")
        // PDT is UTC-7 no matter the date.
        #expect(plain(try #require(answer("9:00 am pdt to et")).copyText) == "11:00 AM")
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

    @Test func citiesWorkOnlyInAnExplicitConversion() throws {
        #expect(plain(try #require(answer("9am tokyo to new york")).copyText) == "7:00 PM yesterday")
        #expect(answer("9:00 paris") == nil)
    }

    @Test(arguments: ["25:00 pt", "13pm pt", "0am pt", "9:61 pt", "9 pt", "pt", "9am", "9am foo", "9am pt to foo"])
    func invalidTimesAreLeftAlone(query: String) {
        #expect(answer(query) == nil)
    }

    @Test func skippedTimesDuringSpringForwardAreRejected() {
        // 2026-03-08 10:00 UTC, in the US. 2:30 AM never happened in Los Angeles.
        let springForward = Date(timeIntervalSince1970: 1_772_964_000)
        #expect(SmartSearchAnswer.evaluate("2:30 am pt", now: springForward, localZone: newYork) == nil)
        #expect(SmartSearchAnswer.evaluate("3:30 am pt", now: springForward, localZone: newYork) != nil)
    }
}
