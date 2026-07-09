// M3
// Shared value types for the transcript pipeline (docs/specs/M3-transcripts.md
// §2). Pure, Sendable, platform-agnostic — no SwiftData, no Speech import.
import Foundation

/// One cue from a parsed feed transcript (SRT/VTT/Podcasting-2.0 JSON).
/// No word-level timing — feed transcripts are cue/paragraph granularity.
public struct RawTranscriptCue: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var speaker: String?

    public init(start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// One attributed run from a finalized SpeechTranscriber result — treat as
/// "approximately one word or token." `text` is the exact substring sliced
/// from the transcriber's AttributedString for that run's range: it already
/// carries whatever spacing/punctuation the framework naturally produces.
/// Concatenating a sequence of `RawTranscriptWord.text` values with NO
/// separator reproduces the original text exactly. Never trim or re-space it.
public struct RawTranscriptWord: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Canonical output of `SegmentNormalizer`; maps 1:1 onto `TranscriptSegment`
/// fields (architecture §4) but is a plain value type so it's Sendable and
/// testable without SwiftData.
public struct NormalizedSegment: Sendable, Equatable {
    public var index: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var wordTimings: [WordTiming]

    public init(index: Int, startTime: TimeInterval, endTime: TimeInterval, text: String, wordTimings: [WordTiming] = []) {
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.wordTimings = wordTimings
    }
}
