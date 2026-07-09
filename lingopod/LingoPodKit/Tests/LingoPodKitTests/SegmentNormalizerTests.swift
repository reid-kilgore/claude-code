// M3
// Covers SegmentNormalizer's one-shot (feed) and streaming (on-device) entry
// points against the worked examples in docs/specs/M3-transcripts.md §4.8.
import Testing
import Foundation
@testable import LingoPodKit

@Suite("SegmentNormalizer")
struct SegmentNormalizerTests {

    // MARK: - Example A: tiny-cue merge

    @Test func tinyCueMergeProducesOneSegment() {
        let cues = [
            RawTranscriptCue(start: 0.0, end: 1.0, text: "Yeah.", speaker: nil),
            RawTranscriptCue(start: 1.0, end: 1.4, text: "So,", speaker: nil),
            RawTranscriptCue(start: 1.4, end: 5.0, text: "today we're going to talk about the history of coffee in Ethiopia.", speaker: nil),
        ]
        let segments = SegmentNormalizer.normalize(cues: cues)
        #expect(segments.count == 1)
        #expect(segments[0].index == 0)
        #expect(segments[0].startTime == 0.0)
        #expect(segments[0].endTime == 5.0)
        #expect(segments[0].text == "Yeah. So, today we're going to talk about the history of coffee in Ethiopia.")
        #expect(segments[0].wordTimings.isEmpty)
    }

    // MARK: - Example B: proportional split of a long, punctuation-poor cue

    @Test func longPunctuationPoorCueSplitsProportionally() {
        let words = (1...20).map { "word\($0)" }
        let longText = words.joined(separator: " ") + "."
        #expect(longText.utf16.count > 90)

        let cue = RawTranscriptCue(start: 10.0, end: 22.0, text: longText, speaker: nil)
        let segments = SegmentNormalizer.normalize(cues: [cue])

        #expect(segments.count == 2)
        for segment in segments {
            #expect(segment.text.utf16.count <= 90)
        }
        #expect(segments[0].startTime == 10.0)
        #expect(segments[1].endTime == 22.0)
        // Contiguous: the split boundary is shared between the two halves.
        #expect(segments[0].endTime == segments[1].startTime)
        #expect(segments.map(\.index) == [0, 1])
    }

    // MARK: - Force breaks under the char/duration caps

    @Test func speakerChangeForcesBreakUnderCaps() {
        let cues = [
            RawTranscriptCue(start: 0, end: 1, text: "Hi.", speaker: "Alice"),
            RawTranscriptCue(start: 1, end: 2, text: "Hello.", speaker: "Bob"),
        ]
        let segments = SegmentNormalizer.normalize(cues: cues)
        #expect(segments.count == 2)
        #expect(segments[0].text == "Hi.")
        #expect(segments[1].text == "Hello.")
        #expect(segments.map(\.index) == [0, 1])
    }

    @Test func silenceGapForcesBreakUnderCaps() {
        let cues = [
            RawTranscriptCue(start: 0, end: 1, text: "Short one.", speaker: nil),
            // gap = 4 - 1 = 3s >= silenceGapBreak (2s)
            RawTranscriptCue(start: 4, end: 5, text: "Another short one.", speaker: nil),
        ]
        let segments = SegmentNormalizer.normalize(cues: cues)
        #expect(segments.count == 2)
        #expect(segments[0].text == "Short one.")
        #expect(segments[1].text == "Another short one.")
    }

    @Test func subTwoSecondGapDoesNotForceBreak() {
        let cues = [
            RawTranscriptCue(start: 0, end: 1, text: "Short one.", speaker: nil),
            RawTranscriptCue(start: 2, end: 3, text: "Right after.", speaker: nil),
        ]
        let segments = SegmentNormalizer.normalize(cues: cues)
        #expect(segments.count == 1)
        #expect(segments[0].text == "Short one. Right after.")
    }

    // MARK: - Monotonicity / non-overlap (§4.7)

    @Test func overlappingCuesProduceMonotonicNonOverlappingOutput() {
        let cues = [
            RawTranscriptCue(start: 0, end: 3, text: "First cue.", speaker: "A"),
            // Overlaps [0,3); speaker change also forces a break regardless.
            RawTranscriptCue(start: 2, end: 5, text: "Second cue.", speaker: "B"),
        ]
        let segments = SegmentNormalizer.normalize(cues: cues)
        #expect(segments.count == 2)
        #expect(segments[0].endTime == 3.0)
        // Clamped forward to the previous segment's endTime (§4.7).
        #expect(segments[1].startTime == 3.0)
        #expect(segments[1].endTime == 5.0)
        for i in 1..<segments.count {
            #expect(segments[i].startTime >= segments[i - 1].endTime)
        }
    }

    // MARK: - Index assignment

    @Test func indexIsSequentialWithNoGapsRegardlessOfMerging() {
        let cues = [
            RawTranscriptCue(start: 0.0, end: 1.0, text: "One.", speaker: "A"),
            RawTranscriptCue(start: 1.0, end: 2.0, text: "Two.", speaker: "B"),
            RawTranscriptCue(start: 2.0, end: 3.0, text: "Three.", speaker: "A"),
        ]
        let segments = SegmentNormalizer.normalize(cues: cues)
        for (i, segment) in segments.enumerated() {
            #expect(segment.index == i)
        }
    }

    // MARK: - Word-path streaming (§4.6, Example C)

    @Test func wordPathKeepsSentenceIntactAcrossBatchBoundaryAndFlushesTailOnFinalize() {
        var state = SegmentNormalizer.StreamState()

        let batch1 = [
            RawTranscriptWord(text: "Coffee", start: 0.00, end: 0.42),
            RawTranscriptWord(text: " originated", start: 0.42, end: 1.10),
        ]
        let closedFromBatch1 = SegmentNormalizer.normalizeIncremental(newWords: batch1, state: &state)
        #expect(closedFromBatch1.isEmpty)

        let batch2 = [
            RawTranscriptWord(text: " in", start: 1.10, end: 1.25),
            RawTranscriptWord(text: " Ethiopia.", start: 1.25, end: 2.00),
            RawTranscriptWord(text: " It's", start: 2.00, end: 2.30),
            RawTranscriptWord(text: " now", start: 2.30, end: 2.55),
            RawTranscriptWord(text: " grown", start: 2.55, end: 2.90),
        ]
        let closedFromBatch2 = SegmentNormalizer.normalizeIncremental(newWords: batch2, state: &state)
        #expect(closedFromBatch2.count == 1)
        #expect(closedFromBatch2[0].text == "Coffee originated in Ethiopia.")
        #expect(closedFromBatch2[0].startTime == 0.00)
        #expect(closedFromBatch2[0].endTime == 2.00)

        let tail = SegmentNormalizer.finalizeStream(state: &state)
        #expect(tail.count == 1)
        #expect(tail[0].text == "It's now grown")
        #expect(tail[0].startTime == 2.00)
        #expect(tail[0].endTime == 2.90)

        // finalizeStream on an already-empty builder returns nothing.
        var emptyState = SegmentNormalizer.StreamState()
        #expect(SegmentNormalizer.finalizeStream(state: &emptyState).isEmpty)
    }

    @Test func wordTimingsRangeInSegmentTextRoundTripsExactly() {
        var state = SegmentNormalizer.StreamState()
        let words = [
            RawTranscriptWord(text: "Coffee", start: 0.00, end: 0.42),
            RawTranscriptWord(text: " originated", start: 0.42, end: 1.10),
            RawTranscriptWord(text: " in", start: 1.10, end: 1.25),
            RawTranscriptWord(text: " Ethiopia.", start: 1.25, end: 2.00),
        ]
        _ = SegmentNormalizer.normalizeIncremental(newWords: words, state: &state)
        let segments = SegmentNormalizer.finalizeStream(state: &state)
        #expect(segments.count == 1)
        let segment = segments[0]
        #expect(!segment.wordTimings.isEmpty)
        for timing in segment.wordTimings {
            let utf16 = Array(segment.text.utf16)
            let lower = timing.rangeInSegmentText.lowerBound
            let upper = timing.rangeInSegmentText.upperBound
            #expect(lower >= 0 && upper <= utf16.count && lower <= upper)
            let slice = utf16[lower..<upper]
            let sliced = String(decoding: slice, as: UTF16.self)
            #expect(sliced == timing.text)
        }
    }

    // MARK: - normalize(cues:) on empty input

    @Test func emptyCuesProduceEmptySegments() {
        #expect(SegmentNormalizer.normalize(cues: []).isEmpty)
    }
}
