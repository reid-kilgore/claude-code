// M1
import Testing
import Foundation
@testable import LingoPodKit

@Suite("ITunesDurationParser")
struct ITunesDurationParserTests {
    @Test(arguments: [
        ("00:45", 45.0),
        ("1:05:00", 3900.0),
        ("3661", 3661.0),
        ("3661.5", 3661.5),
    ])
    func validShapesParseCorrectly(input: String, expected: TimeInterval) {
        #expect(ITunesDurationParser.parse(input) == expected)
    }

    @Test(arguments: ["", "invalid", "25:99", "1:2:3:4"])
    func invalidShapesReturnNil(input: String) {
        #expect(ITunesDurationParser.parse(input) == nil)
    }

    @Test func wholeSecondsHHMMSS() {
        #expect(ITunesDurationParser.parse("00:00:05") == 5)
    }
}
