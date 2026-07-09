// M3
// SubRip (.srt) parser, pure/static, no instances (docs/specs/M3-transcripts.md
// §3.1). Never force-unwraps; skips individually-malformed blocks rather than
// failing the whole file (only throws `.emptyInput` if *zero* cues parse out
// of non-empty input).
import Foundation

public enum SRTParser {
    public static func parse(_ contents: String) throws -> [RawTranscriptCue] {
        let normalized = TranscriptTextNormalization.normalize(contents)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptParseError.emptyInput
        }

        let blocks = TranscriptTextNormalization.splitIntoBlocks(normalized)
        var cues: [RawTranscriptCue] = []
        for block in blocks {
            if let cue = parseBlock(block) {
                cues.append(cue)
            }
            // Malformed blocks are silently skipped (spec §3.1: "skip just
            // that one block ... so one bad cue doesn't blank the entire
            // transcript"). No individual `.malformedTimestamp` is thrown
            // per block; only the aggregate "zero cues parsed" case below
            // surfaces an error.
        }

        guard !cues.isEmpty else {
            throw TranscriptParseError.emptyInput
        }
        return cues
    }

    /// Returns `nil` if the block can't be parsed as a valid cue (malformed
    /// timestamp, no timestamp line at all, or empty resulting text).
    private static func parseBlock(_ lines: [String]) -> RawTranscriptCue? {
        guard !lines.isEmpty else { return nil }

        // First non-blank line is a sequence number, parsed tolerantly: if
        // it's not an integer, treat that same line as the timestamp line
        // instead (some malformed SRTs omit the index).
        let hasSequenceNumber = Int(lines[0].trimmingCharacters(in: .whitespaces)) != nil
        let timestampLineIndex = hasSequenceNumber ? 1 : 0
        guard timestampLineIndex < lines.count else { return nil }

        guard let (start, end) = parseTimestampLine(lines[timestampLineIndex]) else {
            return nil
        }

        let textLines = lines[(timestampLineIndex + 1)...]
        let text = TranscriptTextNormalization.collapseWhitespace(textLines.joined(separator: " "))
        guard !text.isEmpty else { return nil }

        return RawTranscriptCue(start: start, end: end, text: text, speaker: nil)
    }

    /// `HH:MM:SS,mmm --> HH:MM:SS,mmm`, optionally followed by cue settings
    /// tokens (ignored). Only the first two whitespace-delimited tokens
    /// around the arrow are parsed as timestamps.
    private static func parseTimestampLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let leftPart = line[line.startIndex..<arrowRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let rightPart = line[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let endToken = rightPart.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return nil
        }
        guard let start = parseSRTTimestamp(leftPart), let end = parseSRTTimestamp(String(endToken)) else {
            return nil
        }
        return (start, end)
    }

    /// `HH:MM:SS,mmm` (hours always present/required in SRT). Accepts `.`
    /// as well as `,` for the decimal separator (some generators emit
    /// VTT-style timestamps inside `.srt` files).
    private static func parseSRTTimestamp(_ raw: String) -> TimeInterval? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        guard let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else {
            return nil
        }
        guard hours >= 0, minutes >= 0, seconds >= 0 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
