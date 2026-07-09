// M1
import Testing
@testable import LingoPodKit

@Suite("HTMLStripper")
struct HTMLStripperTests {
    @Test func plainTextIsNoOpModuloWhitespaceCollapsing() {
        #expect(HTMLStripper.strip("Hello world") == "Hello world")
        #expect(HTMLStripper.strip("  Hello   world  \n") == "Hello world")
    }

    @Test func paragraphsCollapseToSpaceJoinedText() {
        let input = "<p>First paragraph.</p><p>Second paragraph.</p>"
        #expect(HTMLStripper.strip(input) == "First paragraph. Second paragraph.")
    }

    @Test func anchorKeepsOnlyLinkText() {
        let input = #"Check out <a href="https://example.com">this link</a> today."#
        #expect(HTMLStripper.strip(input) == "Check out this link today.")
    }

    @Test func commonEntitiesDecodeCorrectly() {
        #expect(HTMLStripper.strip("Rock &amp; Roll") == "Rock & Roll")
        #expect(HTMLStripper.strip("&quot;Radio&quot;") == "\"Radio\"")
        #expect(HTMLStripper.strip("it&#39;s") == "it's")
        #expect(HTMLStripper.strip("it&apos;s") == "it's")
        #expect(HTMLStripper.strip("a&nbsp;b") == "a b")
    }

    @Test func nestedMalformedTagsDontCrashAndProduceReasonableOutput() {
        let input = "<p><b>bold</p> and more text"
        let result = HTMLStripper.strip(input)
        #expect(!result.contains("<"))
        #expect(!result.contains(">"))
        #expect(result.contains("bold"))
        #expect(result.contains("and more text"))
    }

    @Test func emptyStringIsEmpty() {
        #expect(HTMLStripper.strip("") == "")
    }
}
