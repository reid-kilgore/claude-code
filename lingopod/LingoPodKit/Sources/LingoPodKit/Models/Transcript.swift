// M0
// SwiftData model (architecture §4, verbatim field set; §11.1). See
// Podcast.swift for the note on why `public`/`init` are added beyond the
// architecture doc's pseudocode.
import Foundation
import SwiftData

@Model
public final class Transcript {
    public var episode: Episode?
    public var source: TranscriptSource
    /// BCP-47 actually used.
    public var languageCode: String
    public var state: TranscriptState
    public var generatedAt: Date

    /// Ordered by `startTime`.
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.transcript)
    public var segments: [TranscriptSegment] = []

    public init(
        episode: Episode? = nil,
        source: TranscriptSource,
        languageCode: String,
        state: TranscriptState = .pending,
        generatedAt: Date = .now
    ) {
        self.episode = episode
        self.source = source
        self.languageCode = languageCode
        self.state = state
        self.generatedAt = generatedAt
    }
}
