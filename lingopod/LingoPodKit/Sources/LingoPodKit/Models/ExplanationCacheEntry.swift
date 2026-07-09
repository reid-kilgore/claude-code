// M0
// SwiftData model (architecture §4, verbatim field set; §11.1). See
// Podcast.swift for the note on why `public`/`init` are added beyond the
// architecture doc's pseudocode.
//
// `explanationJSON` decodes to `PassageExplanation` (architecture §5.4),
// which lives in the app target (not here) because it depends on
// FoundationModels' `@Generable` macro — `LingoPodKit` has no UIKit/
// SwiftUI/FoundationModels imports (architecture §1). Storing it as `Data`
// here keeps the model framework-agnostic; the app target encodes/decodes.
import Foundation
import SwiftData

@Model
public final class ExplanationCacheEntry {
    /// SHA-256 of `"source|target|normalizedPassage|normalizedContext"`
    /// (architecture §11.6).
    @Attribute(.unique) public var key: String
    public var passage: String
    /// Encoded `PassageExplanation` (architecture §5.4).
    public var explanationJSON: Data
    public var createdAt: Date

    public init(
        key: String,
        passage: String,
        explanationJSON: Data,
        createdAt: Date = .now
    ) {
        self.key = key
        self.passage = passage
        self.explanationJSON = explanationJSON
        self.createdAt = createdAt
    }
}
