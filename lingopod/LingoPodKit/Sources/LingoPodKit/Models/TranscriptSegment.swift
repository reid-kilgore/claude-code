// M0
// SwiftData model (architecture §4, verbatim field set; §11.1). See
// Podcast.swift for the note on why `public`/`init` are added beyond the
// architecture doc's pseudocode.
import Foundation
import SwiftData

@Model
public final class TranscriptSegment {
    public var transcript: Transcript?
    /// Stable ordering key.
    public var index: Int
    /// Seconds from episode start.
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    /// Display text, one "line" in the overlay.
    public var text: String
    /// Codable value array; empty for coarse feed transcripts.
    public var wordTimings: [WordTiming]

    public init(
        transcript: Transcript? = nil,
        index: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        wordTimings: [WordTiming] = []
    ) {
        self.transcript = transcript
        self.index = index
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.wordTimings = wordTimings
    }
}
