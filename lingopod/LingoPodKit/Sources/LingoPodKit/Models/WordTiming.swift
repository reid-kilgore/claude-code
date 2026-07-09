// M0
// SwiftData model support type (architecture §4, §11.1). Value type stored
// inside `TranscriptSegment.wordTimings`; empty for coarse feed
// transcripts that don't carry word-level timing.
import Foundation

public struct WordTiming: Codable, Hashable, Sendable {
    public var text: String
    /// Absolute, seconds from episode start.
    public var start: TimeInterval
    public var end: TimeInterval
    /// UTF-16 offsets into the owning `TranscriptSegment.text`.
    public var rangeInSegmentText: Range<Int>

    public init(text: String, start: TimeInterval, end: TimeInterval, rangeInSegmentText: Range<Int>) {
        self.text = text
        self.start = start
        self.end = end
        self.rangeInSegmentText = rangeInSegmentText
    }
}
