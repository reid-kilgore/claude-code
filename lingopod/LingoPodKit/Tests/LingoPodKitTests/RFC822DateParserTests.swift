// M1
import Testing
import Foundation
@testable import LingoPodKit

@Suite("RFC822DateParser")
struct RFC822DateParserTests {
    /// Round-trip sanity check with exact UTC component comparison, not
    /// just "non-nil" -- this is the meaningful check for the
    /// `en_US_POSIX` locale requirement: a wrong-locale bug produces `nil`
    /// (DateFormatter's all-or-nothing symbolic matching), not a
    /// wrong-but-non-nil date, so a non-nil-with-correct-components
    /// assertion actually guards the regression.
    @Test func validRFC822ComponentsMatchExactly() throws {
        let date = try #require(RFC822DateParser.parse("Mon, 06 Sep 2021 08:00:00 GMT"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(components.year == 2021)
        #expect(components.month == 9)
        #expect(components.day == 6)
        #expect(components.hour == 8)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    @Test func missingWeekdayParses() {
        #expect(RFC822DateParser.parse("06 Sep 2021 08:00:00 GMT") != nil)
    }

    @Test func garbageStringReturnsNilNotThrows() {
        #expect(RFC822DateParser.parse("not a date") == nil)
    }

    @Test func isoInPubDateParses() {
        #expect(RFC822DateParser.parse("2021-09-06T08:00:00Z") != nil)
    }

    @Test func emptyAndWhitespaceReturnNil() {
        #expect(RFC822DateParser.parse("") == nil)
        #expect(RFC822DateParser.parse("   ") == nil)
    }
}
