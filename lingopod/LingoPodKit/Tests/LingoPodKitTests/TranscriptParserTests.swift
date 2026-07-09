// M3
// Covers SRTParser, VTTParser, PodcastIndexJSONTranscriptParser, and
// TranscriptFormatSniffer (docs/specs/M3-transcripts.md §10). Fixtures live
// under Fixtures/Transcripts/ (kept in a subdirectory to avoid colliding
// with M1's RSS fixtures directly under Fixtures/).
import Testing
import Foundation
@testable import LingoPodKit

private enum FixtureError: Error {
    case missing(String)
}

private func loadFixtureString(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Transcripts") else {
        throw FixtureError.missing(name)
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private func loadFixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Transcripts") else {
        throw FixtureError.missing(name)
    }
    return try Data(contentsOf: url)
}

// MARK: - SRTParser

@Suite("SRTParser")
struct SRTParserTests {
    @Test func basicParseProducesExpectedCues() throws {
        let contents = try loadFixtureString("basic.srt")
        let cues = try SRTParser.parse(contents)
        #expect(cues.count == 2)
        #expect(cues[0].start == 1.0)
        #expect(cues[0].end == 4.0)
        #expect(cues[0].text == "Hello world.")
        #expect(cues[0].speaker == nil)
        #expect(cues[1].start == 4.5)
        #expect(cues[1].end == 8.0)
        #expect(cues[1].text == "This is a test, across two lines.")
    }

    @Test func crlfParsesIdenticallyToLF() throws {
        let lfContents = try loadFixtureString("basic.srt")
        let crlfContents = try loadFixtureString("crlf.srt")
        let lfCues = try SRTParser.parse(lfContents)
        let crlfCues = try SRTParser.parse(crlfContents)
        #expect(lfCues == crlfCues)
    }

    @Test func overlappingCuesParseFaithfullyWithoutReordering() throws {
        let contents = try loadFixtureString("overlapping.srt")
        let cues = try SRTParser.parse(contents)
        #expect(cues.count == 2)
        #expect(cues[0].start == 0.0 && cues[0].end == 3.0)
        // The parser must NOT clamp/reorder the overlap -- that's the
        // normalizer's job (§4.7).
        #expect(cues[1].start == 2.0 && cues[1].end == 5.0)
    }

    @Test func malformedBlockIsSkippedValidBlocksStillParse() throws {
        let contents = try loadFixtureString("malformed.srt")
        let cues = try SRTParser.parse(contents)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Valid cue one.")
        #expect(cues[1].text == "Valid cue two.")
    }

    @Test func allMalformedInputThrowsEmptyInput() {
        let contents = "1\nnot a timestamp\nsome text\n"
        do {
            _ = try SRTParser.parse(contents)
            Issue.record("Expected TranscriptParseError.emptyInput to be thrown")
        } catch let error as TranscriptParseError {
            #expect(error == .emptyInput)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func blankInputThrowsEmptyInput() {
        do {
            _ = try SRTParser.parse("   \n\n  ")
            Issue.record("Expected TranscriptParseError.emptyInput to be thrown")
        } catch let error as TranscriptParseError {
            #expect(error == .emptyInput)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func commaAndDotDecimalSeparatorsBothAccepted() throws {
        let comma = "1\n00:00:01,500 --> 00:00:02,500\nComma.\n"
        let dot = "1\n00:00:01.500 --> 00:00:02.500\nDot.\n"
        let commaCues = try SRTParser.parse(comma)
        let dotCues = try SRTParser.parse(dot)
        #expect(commaCues[0].start == 1.5 && commaCues[0].end == 2.5)
        #expect(dotCues[0].start == 1.5 && dotCues[0].end == 2.5)
    }

    @Test func toleratesMissingSequenceNumber() throws {
        let contents = "00:00:00,000 --> 00:00:01,000\nNo index line.\n"
        let cues = try SRTParser.parse(contents)
        #expect(cues.count == 1)
        #expect(cues[0].text == "No index line.")
    }

    @Test func ignoresTrailingCueSettingsTokens() throws {
        let contents = "1\n00:00:00,000 --> 00:00:01,000 X1:040 X2:190\nWith settings.\n"
        let cues = try SRTParser.parse(contents)
        #expect(cues.count == 1)
        #expect(cues[0].start == 0.0 && cues[0].end == 1.0)
    }
}

// MARK: - VTTParser

@Suite("VTTParser")
struct VTTParserTests {
    @Test func basicHeaderAndIdentifierLineVariants() throws {
        let contents = try loadFixtureString("basic.vtt")
        let cues = try VTTParser.parse(contents)
        #expect(cues.count == 2)
        // First cue has an optional identifier line ("intro-1") before the
        // timestamp; must not be mistaken for cue text.
        #expect(cues[0].text == "Hello world.")
        #expect(cues[0].start == 1.0 && cues[0].end == 4.0)
        #expect(cues[1].text == "This is a test.")
    }

    @Test func headerWithTrailingDescriptionParses() throws {
        let contents = "WEBVTT - sample file\n\n00:00:01.000 --> 00:00:02.000\nHi.\n"
        let cues = try VTTParser.parse(contents)
        #expect(cues.count == 1)
    }

    @Test func missingHeaderParsesLeniently() throws {
        let contents = "00:00:01.000 --> 00:00:02.000\nNo header here.\n"
        let cues = try VTTParser.parse(contents)
        #expect(cues.count == 1)
        #expect(cues[0].text == "No header here.")
    }

    @Test func missingHeaderAndNoCuesThrowsUnrecognizedFormat() {
        let contents = "just some\nplain text\nwith no cues at all\n"
        do {
            _ = try VTTParser.parse(contents)
            Issue.record("Expected TranscriptParseError.unrecognizedFormat to be thrown")
        } catch let error as TranscriptParseError {
            #expect(error == .unrecognizedFormat)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func hoursPresentAndHoursOmittedProduceEquivalentSeconds() throws {
        let withHours = try loadFixtureString("basic.vtt")
        let withoutHours = try loadFixtureString("no_hours.vtt")
        let hoursCues = try VTTParser.parse(withHours)
        let noHoursCues = try VTTParser.parse(withoutHours)
        #expect(hoursCues.map(\.start) == noHoursCues.map(\.start))
        #expect(hoursCues.map(\.end) == noHoursCues.map(\.end))
    }

    @Test func cueSettingsTokensDontBreakTimestampParsing() throws {
        let contents = try loadFixtureString("cue_settings.vtt")
        let cues = try VTTParser.parse(contents)
        #expect(cues.count == 2)
        #expect(cues[0].start == 1.0 && cues[0].end == 4.0)
        #expect(cues[0].text == "First cue with settings.")
        #expect(cues[1].start == 4.0 && cues[1].end == 7.0)
    }

    @Test func voiceTagsExtractSpeakerAndStripMarkup() throws {
        let contents = try loadFixtureString("voice_tags.vtt")
        let cues = try VTTParser.parse(contents)
        #expect(cues.count == 2)
        #expect(cues[0].speaker == "Host")
        #expect(cues[0].text == "Hello, welcome to the show.")
        #expect(cues[1].speaker == "Guest")
        #expect(cues[1].text == "Thanks for having me.")
    }

    @Test func otherMarkupStrippedFromText() throws {
        let contents = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<b>Bold</b> and <c.loud>loud</c> and <00:00:01.500>timed.\n"
        let cues = try VTTParser.parse(contents)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Bold and loud and timed.")
    }

    @Test func htmlEntitiesDecoded() throws {
        let contents = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nTom &amp; Jerry &lt;3 &quot;fun&quot; &amp;nbsp;done\n"
        let cues = try VTTParser.parse(contents)
        #expect(cues.count == 1)
        #expect(cues[0].text.contains("Tom & Jerry"))
        #expect(cues[0].text.contains("<3"))
        #expect(cues[0].text.contains("\"fun\""))
    }

    @Test func notesStyleRegionBlocksProduceZeroCuesForThemselves() throws {
        let contents = try loadFixtureString("notes_and_regions.vtt")
        let cues = try VTTParser.parse(contents)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Real cue after the metadata blocks.")
        #expect(cues[1].text == "Another real cue.")
    }

    @Test func malformedCueSkippedValidCuesStillParse() throws {
        let contents = try loadFixtureString("malformed.vtt")
        let cues = try VTTParser.parse(contents)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Valid first cue.")
        #expect(cues[1].text == "Valid second cue.")
    }
}

// MARK: - PodcastIndexJSONTranscriptParser

@Suite("PodcastIndexJSONTranscriptParser")
struct PodcastIndexJSONTranscriptParserTests {
    @Test func basicParse() throws {
        let data = try loadFixtureData("basic.json")
        let cues = try PodcastIndexJSONTranscriptParser.parse(data)
        #expect(cues.count == 2)
        #expect(cues[0].speaker == "Host")
        #expect(cues[0].start == 0.78)
        #expect(cues[0].end == 4.32)
        #expect(cues[0].text == "Hello and welcome to the show.")
    }

    @Test func missingSpeakerIsNilNotAThrowAndEmptyBodyFiltered() throws {
        let data = try loadFixtureData("missing_speaker.json")
        let cues = try PodcastIndexJSONTranscriptParser.parse(data)
        // Third segment (whitespace-only body) must be filtered out.
        #expect(cues.count == 2)
        #expect(cues[0].speaker == nil)
        #expect(cues[1].speaker == "Guest")
    }

    @Test func unsortedInputSortedByStartTime() throws {
        let data = try loadFixtureData("unsorted.json")
        let cues = try PodcastIndexJSONTranscriptParser.parse(data)
        #expect(cues.count == 2)
        #expect(cues[0].start == 0.0)
        #expect(cues[1].start == 5.0)
    }

    @Test func bareArrayFallbackParses() throws {
        let data = try loadFixtureData("bare_array.json")
        let cues = try PodcastIndexJSONTranscriptParser.parse(data)
        #expect(cues.count == 2)
        #expect(cues[0].text == "Bare array segment one.")
    }

    @Test func malformedJSONThrows() throws {
        let data = try loadFixtureData("malformed.json")
        do {
            _ = try PodcastIndexJSONTranscriptParser.parse(data)
            Issue.record("Expected TranscriptParseError.malformedJSON to be thrown")
        } catch let error as TranscriptParseError {
            guard case .malformedJSON = error else {
                Issue.record("Expected .malformedJSON, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

// MARK: - TranscriptFormatSniffer

@Suite("TranscriptFormatSniffer")
struct TranscriptFormatSnifferTests {
    @Test func detectsByMIMEType() {
        let url = URL(string: "https://example.com/transcript")!
        #expect(TranscriptFormatSniffer.detect(mimeType: "text/vtt", url: url, data: Data()) == .vtt)
        #expect(TranscriptFormatSniffer.detect(mimeType: "application/json; charset=utf-8", url: url, data: Data()) == .podcastIndexJSON)
        #expect(TranscriptFormatSniffer.detect(mimeType: "application/x-subrip", url: url, data: Data()) == .srt)
    }

    @Test func fallsBackToExtensionWhenMIMEUnrecognized() {
        let url = URL(string: "https://example.com/transcript.vtt")!
        #expect(TranscriptFormatSniffer.detect(mimeType: nil, url: url, data: Data()) == .vtt)
        #expect(TranscriptFormatSniffer.detect(mimeType: "application/octet-stream", url: url, data: Data()) == .vtt)
    }

    @Test func fallsBackToContentSniffWhenMIMEAndExtensionUnresolved() {
        let url = URL(string: "https://example.com/transcript")!
        let vttData = Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n".utf8)
        #expect(TranscriptFormatSniffer.detect(mimeType: nil, url: url, data: vttData) == .vtt)

        let jsonData = Data("{\"segments\":[]}".utf8)
        #expect(TranscriptFormatSniffer.detect(mimeType: nil, url: url, data: jsonData) == .podcastIndexJSON)

        let srtData = Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8)
        #expect(TranscriptFormatSniffer.detect(mimeType: nil, url: url, data: srtData) == .srt)
    }

    @Test func returnsNilWhenNothingMatches() {
        let url = URL(string: "https://example.com/transcript")!
        #expect(TranscriptFormatSniffer.detect(mimeType: nil, url: url, data: Data("garbage".utf8)) == nil)
    }
}
