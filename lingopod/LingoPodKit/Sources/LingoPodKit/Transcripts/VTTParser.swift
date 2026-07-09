// M3
// WebVTT (.vtt) parser, pure/static, no instances (docs/specs/M3-transcripts.md
// §3.2). Faithful extraction only — does not sort or dedupe; `SegmentNormalizer`
// enforces monotonic, non-overlapping output.
import Foundation

public enum VTTParser {
    public static func parse(_ contents: String) throws -> [RawTranscriptCue] {
        let normalized = TranscriptTextNormalization.normalize(contents)
        let allBlocks = TranscriptTextNormalization.splitIntoBlocks(normalized)

        var blocks = allBlocks
        var headerPresent = false
        if let first = blocks.first, let firstLine = first.first, firstLine.hasPrefix("WEBVTT") {
            headerPresent = true
            blocks.removeFirst()
        }

        var cues: [RawTranscriptCue] = []
        for block in blocks {
            guard !isSkippedBlock(block) else { continue }
            if let cue = parseCueBlock(block) {
                cues.append(cue)
            }
        }

        if cues.isEmpty, !headerPresent {
            throw TranscriptParseError.unrecognizedFormat
        }
        return cues
    }

    /// `NOTE`, `STYLE`, `REGION` blocks are identified by their first
    /// line's prefix (case-sensitive) and skipped entirely, without
    /// attempting to parse their contents as cues.
    private static func isSkippedBlock(_ block: [String]) -> Bool {
        guard let first = block.first else { return true }
        return first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION")
    }

    private static func parseCueBlock(_ block: [String]) -> RawTranscriptCue? {
        guard !block.isEmpty else { return nil }

        let timestampLineIndex: Int
        if block[0].contains("-->") {
            timestampLineIndex = 0
        } else {
            // Optional cue identifier line (any text not containing "-->").
            timestampLineIndex = 1
            guard timestampLineIndex < block.count, block[timestampLineIndex].contains("-->") else {
                return nil
            }
        }

        guard let (start, end) = parseTimestampLine(block[timestampLineIndex]) else {
            return nil
        }

        let payloadLines = block[(timestampLineIndex + 1)...]
        let rawPayload = payloadLines.joined(separator: " ")
        let (strippedText, speaker) = extractSpeakerAndStripMarkup(rawPayload)
        let decoded = decodeHTMLEntities(strippedText)
        let text = TranscriptTextNormalization.collapseWhitespace(decoded)
        guard !text.isEmpty else { return nil }

        return RawTranscriptCue(start: start, end: end, text: text, speaker: speaker)
    }

    /// `<start> --> <end>` optionally followed by cue settings tokens
    /// (`align:`, `position:`, region id, etc. — discarded).
    private static func parseTimestampLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        guard let arrowRange = line.range(of: "-->") else { return nil }
        let leftPart = line[line.startIndex..<arrowRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let rightPart = line[arrowRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let endToken = rightPart.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return nil
        }
        guard let start = parseVTTTimestamp(leftPart), let end = parseVTTTimestamp(String(endToken)) else {
            return nil
        }
        return (start, end)
    }

    /// Accepts `HH:MM:SS.mmm` (hours present, two colons) and `MM:SS.mmm`
    /// (hours omitted, one colon; hours = 0). Decimal separator is `.` per
    /// the WebVTT spec, but `,` is accepted too for robustness.
    private static func parseVTTTimestamp(_ raw: String) -> TimeInterval? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            guard h >= 0, m >= 0, s >= 0 else { return nil }
            return h * 3600 + m * 60 + s
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            guard m >= 0, s >= 0 else { return nil }
            return m * 60 + s
        default:
            return nil
        }
    }

    /// Extracts the speaker name from the first `<v Speaker Name>` (or
    /// unclosed `<v Speaker Name>` spanning the rest of the payload) span,
    /// then strips *all* tag-shaped markup (`<b>`, `<i>`, `<u>`, `<c.class>`,
    /// `<ruby>`, `<rt>`, `<v ...>`/`</v>`, timestamp tags like
    /// `<00:00:03.500>`), keeping the inner text. If more than one `<v>`
    /// span appears, the first speaker found wins but all text is still
    /// concatenated (v1 simplification, §3.2).
    private static func extractSpeakerAndStripMarkup(_ payload: String) -> (text: String, speaker: String?) {
        var speaker: String?
        if let regex = try? NSRegularExpression(pattern: "<v\\s+([^>]+)>") {
            let range = NSRange(payload.startIndex..<payload.endIndex, in: payload)
            if let match = regex.firstMatch(in: payload, range: range), match.numberOfRanges > 1,
               let group = Range(match.range(at: 1), in: payload) {
                speaker = String(payload[group]).trimmingCharacters(in: .whitespaces)
            }
        }

        let stripped: String
        if let tagRegex = try? NSRegularExpression(pattern: "<[^>]*>") {
            let range = NSRange(payload.startIndex..<payload.endIndex, in: payload)
            stripped = tagRegex.stringByReplacingMatches(in: payload, range: range, withTemplate: "")
        } else {
            stripped = payload
        }

        return (stripped, speaker)
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        let nonAmpersandEntities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
        ]
        for (entity, replacement) in nonAmpersandEntities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // `&amp;` decoded last so a doubly-escaped `&amp;lt;` doesn't
        // collapse into `<` via the earlier `&lt;` pass.
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }
}
