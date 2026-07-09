// M3
// Typed parse errors for the three feed transcript parsers (SRT/VTT/
// Podcasting-2.0 JSON). docs/specs/M3-transcripts.md §2.
import Foundation

public enum TranscriptParseError: Error, Sendable, Equatable {
    case emptyInput
    case malformedTimestamp(line: String)
    case malformedCueBlock(context: String)
    case malformedJSON(detail: String)
    case unrecognizedFormat
}
