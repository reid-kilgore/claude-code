// Identical copy of LingoPod/App/PassageExplanation.swift (architecture
// §5.4 / M6-explain.md §3.4: "do not modify this type"). Kept byte-for-byte
// the same so the spike proves the exact @Generable shape M6 will ship, not
// a close approximation. If you change this file to make the spike compile,
// port the same change back to LingoPod/App/PassageExplanation.swift and
// docs/01-architecture.md §5.4 together (architecture §5's own rule).
//
// VERIFY(iOS26): exact macro spelling (`@Generable`, `@Guide`, the
// `.count(_:)` guide constraint, and the compiler-synthesized
// `PartiallyGenerated` nested type used by ExplainCommand.swift) is written
// to the shape documented in architecture.md §5.4. If the shipping iOS 26 /
// macOS 26 FoundationModels API differs, update this file and
// docs/01-architecture.md §5.4 together — do not restructure around a guess.
import FoundationModels

@Generable
struct PassageExplanation {
    @Guide(description: "Natural translation of the passage into the target language")
    var translation: String
    @Guide(description: "2-4 sentence explanation of overall meaning, in the target language")
    var meaning: String
    @Guide(description: "Notable grammar constructions, each ≤2 sentences", .count(0...4))
    var grammarNotes: [String]
    @Guide(description: "Idioms/colloquialisms/register notes", .count(0...3))
    var idiomNotes: [String]
}
