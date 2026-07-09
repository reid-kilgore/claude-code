// M3
// Shared, non-public text-normalization helpers used by both `SRTParser`
// and `VTTParser` (docs/specs/M3-transcripts.md §3.1/§3.2: "BOM + CRLF
// handling identical to SRTParser"). Kept internal (not exposed as public
// API) since callers only need the two parsers' public `parse` entry points.
import Foundation

enum TranscriptTextNormalization {
    /// Strips a leading UTF-8 BOM (`\u{FEFF}`) if present, then normalizes
    /// line endings (`\r\n` and bare `\r` both become `\n`).
    static func normalize(_ contents: String) -> String {
        var text = contents
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        return text
    }

    /// Splits normalized text into blocks, separated by one-or-more blank
    /// lines (a "blank" line is empty after trimming whitespace).
    static func splitIntoBlocks(_ normalizedText: String) -> [[String]] {
        let lines = normalizedText.components(separatedBy: "\n")
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current)
        }
        return blocks
    }

    /// Collapses runs of whitespace (including newlines) to a single space,
    /// then trims leading/trailing whitespace.
    static func collapseWhitespace(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
