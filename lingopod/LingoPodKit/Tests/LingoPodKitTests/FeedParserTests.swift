// M1
import Testing
import Foundation
@testable import LingoPodKit

private enum FixtureError: Error {
    case missing(String)
}

private func loadFixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
}

@Suite("FeedParser")
struct FeedParserTests {
    @Test func feedWithTranscriptChannelLevelFields() throws {
        let data = try loadFixture("feed_with_transcript.xml")
        let feed = try FeedParser().parse(data: data)
        #expect(feed.title == "Learn French Radio")
        #expect(feed.description == "A daily French language podcast for learners.")
        #expect(feed.languageCode == "fr-fr")
        #expect(feed.author == "Radio Apprendre")
        #expect(feed.imageURL == URL(string: "https://example.com/art.jpg"))
        #expect(feed.items.count == 3)
    }

    @Test func feedWithTranscriptItemGUIDsAndTranscriptRefs() throws {
        let data = try loadFixture("feed_with_transcript.xml")
        let feed = try FeedParser().parse(data: data)

        let item1 = feed.items[0]
        #expect(item1.guid == "ep-1-guid")
        // FeedParser is a dumb transcriber (spec §4.7) -- it does not
        // resolve the application/json-preferred winner itself; that
        // selection is CatalogService's job (spec §5.6 step 4). Assert
        // both refs are transcribed faithfully, in document order.
        #expect(item1.transcripts.count == 2)
        #expect(item1.transcripts[0].type == "text/vtt")
        #expect(item1.transcripts[0].url == URL(string: "https://example.com/transcripts/ep1.vtt"))
        #expect(item1.transcripts[1].type == "application/json")
        #expect(item1.transcripts[1].url == URL(string: "https://example.com/transcripts/ep1.json"))

        let item2 = feed.items[1]
        #expect(item2.guid == "ep-2-guid")
        #expect(item2.transcripts.count == 1)
        #expect(item2.transcripts[0].type == "application/srt")

        let item3 = feed.items[2]
        #expect(item3.guid == "ep-3-guid")
        #expect(item3.transcripts.isEmpty)
    }

    @Test func feedWithTranscriptDurationsAcrossFormats() throws {
        let data = try loadFixture("feed_with_transcript.xml")
        let feed = try FeedParser().parse(data: data)
        #expect(feed.items[0].durationSeconds == 3723) // "01:02:03"
        #expect(feed.items[1].durationSeconds == 2730) // "45:30"
        #expect(feed.items[2].durationSeconds == 185)  // "185"
    }

    @Test func feedWithTranscriptEnclosuresPresent() throws {
        let data = try loadFixture("feed_with_transcript.xml")
        let feed = try FeedParser().parse(data: data)
        for item in feed.items {
            #expect(item.enclosureURL != nil)
            #expect(item.enclosureType == "audio/mpeg")
        }
    }

    @Test func feedWithoutTranscriptItemCount() throws {
        let data = try loadFixture("feed_without_transcript.xml")
        let feed = try FeedParser().parse(data: data)
        #expect(feed.items.count == 5)
    }

    @Test func feedWithoutTranscriptMissingGUIDFallsBackToEmptyNotEnclosure() throws {
        let data = try loadFixture("feed_without_transcript.xml")
        let feed = try FeedParser().parse(data: data)
        // Item 2 has no <guid> element at all. FeedParser must NOT invent
        // one from the enclosure URL itself -- that fallback is
        // CatalogService's job (spec §4.1, §4.7).
        let item2 = feed.items[1]
        #expect(item2.guid.isEmpty)
        #expect(item2.enclosureURL == URL(string: "https://example.com/tw/2.mp3"))
    }

    @Test func feedWithoutTranscriptCDATADescriptionDecodedAndStripped() throws {
        let data = try loadFixture("feed_without_transcript.xml")
        let feed = try FeedParser().parse(data: data)
        let item3 = feed.items[2]
        #expect(item3.description == "This is bold HTML in a CDATA block.")
    }

    @Test func feedWithoutTranscriptItunesSummaryFallback() throws {
        let data = try loadFixture("feed_without_transcript.xml")
        let feed = try FeedParser().parse(data: data)
        let item4 = feed.items[3]
        #expect(item4.description == "Summary-only description via itunes:summary.")
    }

    @Test func feedWithoutTranscriptChannelImageFallsBackToNestedImageURL() throws {
        let data = try loadFixture("feed_without_transcript.xml")
        let feed = try FeedParser().parse(data: data)
        // No <itunes:image> in this fixture at all -- must fall back to
        // <image><url>.
        #expect(feed.imageURL == URL(string: "https://example.com/tw-art.jpg"))
    }

    @Test func malformedDatesAndNonUTF8EncodingDecodedCorrectly() throws {
        let data = try loadFixture("feed_malformed_dates_and_encoding.xml")
        let feed = try FeedParser().parse(data: data)

        // Non-UTF8 (ISO-8859-1, declared in the XML prolog) channel title
        // and description decoded correctly -- XMLParser must transcode
        // from the raw Data itself (spec §7.6); this fixture's bytes are
        // genuinely ISO-8859-1-encoded, not pre-converted to UTF-8.
        #expect(feed.title == "Café Chronique")
        #expect(feed.description == "Une émission sur le café et la culture.")

        #expect(feed.items.count == 5)
        #expect(feed.items[0].publishedAt != nil) // valid RFC822
        #expect(feed.items[1].publishedAt != nil) // missing weekday
        #expect(feed.items[2].publishedAt == nil) // garbage -> nil, not thrown
        #expect(feed.items[3].publishedAt != nil) // ISO-8601-in-pubDate
        #expect(feed.items[4].durationSeconds == nil) // "1:2:3:4" -> nil, tolerated
    }

    @Test func emptyDataThrowsEmptyDataError() {
        do {
            _ = try FeedParser().parse(data: Data())
            Issue.record("Expected FeedParserError.emptyData to be thrown")
        } catch let error as FeedParserError {
            #expect(error == .emptyData)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func malformedXMLThrowsSyntaxError() {
        let data = Data("<rss><channel>".utf8)
        do {
            _ = try FeedParser().parse(data: data)
            Issue.record("Expected a FeedParserError to be thrown")
        } catch let error as FeedParserError {
            guard case .xmlSyntaxError = error else {
                Issue.record("Expected .xmlSyntaxError, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
