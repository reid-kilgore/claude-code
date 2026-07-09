// M3
// Podcasting 2.0 `podcast:transcript` JSON format parser, pure/static
// (docs/specs/M3-transcripts.md §3.3).
import Foundation

public enum PodcastIndexJSONTranscriptParser {
    public static func parse(_ data: Data) throws -> [RawTranscriptCue] {
        let segments: [PodcastIndexSegment]
        do {
            let document = try JSONDecoder().decode(PodcastIndexTranscriptDocument.self, from: data)
            segments = document.segments
        } catch let objectDecodeError {
            // Tolerate a bare top-level array (some malformed feeds shortcut
            // straight to a bare array of segments) before giving up.
            do {
                segments = try JSONDecoder().decode([PodcastIndexSegment].self, from: data)
            } catch {
                throw TranscriptParseError.malformedJSON(detail: String(describing: objectDecodeError))
            }
        }

        let cues = segments.compactMap { segment -> RawTranscriptCue? in
            let trimmedBody = segment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBody.isEmpty else { return nil }
            return RawTranscriptCue(start: segment.startTime, end: segment.endTime, text: trimmedBody, speaker: segment.speaker)
        }

        // Do not assume input is sorted by startTime; stable sort so ties
        // preserve source order.
        return cues.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.start != rhs.element.start {
                    return lhs.element.start < rhs.element.start
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

private struct PodcastIndexTranscriptDocument: Decodable {
    var segments: [PodcastIndexSegment]
}

private struct PodcastIndexSegment: Decodable {
    var speaker: String?
    var startTime: Double
    var endTime: Double
    var body: String
}
