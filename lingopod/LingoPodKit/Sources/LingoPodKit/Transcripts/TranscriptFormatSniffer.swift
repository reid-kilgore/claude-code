// M3
// Format dispatch used by `TranscriptProvider` to pick which parser to run
// (docs/specs/M3-transcripts.md §3.4). Pure function, no parsing itself.
import Foundation

public enum TranscriptFormat: Sendable, Equatable {
    case srt
    case vtt
    case podcastIndexJSON
}

public enum TranscriptFormatSniffer {
    /// `mimeType` is `Episode.feedTranscriptType` (may be nil or wrong);
    /// `url` is `Episode.feedTranscriptURL` (for extension fallback);
    /// `data` is the fetched bytes (for content-sniff last resort).
    public static func detect(mimeType: String?, url: URL, data: Data) -> TranscriptFormat? {
        if let byMIME = detectByMIME(mimeType) {
            return byMIME
        }
        if let byExtension = detectByExtension(url) {
            return byExtension
        }
        return detectByContent(data)
    }

    private static func detectByMIME(_ mimeType: String?) -> TranscriptFormat? {
        guard let mimeType else { return nil }
        let stripped = mimeType
            .split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !stripped.isEmpty else { return nil }

        switch stripped {
        case "application/json", "application/json+podcast", "text/json":
            return .podcastIndexJSON
        case "text/vtt", "application/x-subrip+vtt":
            return .vtt
        case "application/x-subrip", "text/srt", "application/srt":
            return .srt
        default:
            return nil
        }
    }

    private static func detectByExtension(_ url: URL) -> TranscriptFormat? {
        switch url.pathExtension.lowercased() {
        case "json": return .podcastIndexJSON
        case "vtt": return .vtt
        case "srt": return .srt
        default: return nil
        }
    }

    private static func detectByContent(_ data: Data) -> TranscriptFormat? {
        let prefix = data.prefix(64)
        guard var text = String(data: prefix, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("WEBVTT") {
            return .vtt
        }
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return .podcastIndexJSON
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let firstLine = lines.first, Int(firstLine) != nil, lines.count > 1 {
            let secondLine = lines[1]
            if secondLine.range(of: "^\\d+:\\d+:\\d+[,.]\\d+\\s*-->", options: .regularExpression) != nil {
                return .srt
            }
        }

        return nil
    }
}
