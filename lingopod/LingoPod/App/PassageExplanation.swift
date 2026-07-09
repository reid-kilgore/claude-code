// M0
// Isolates the FoundationModels import (and the `@Generable`/`@Guide`
// macros it provides) in its own file. `Interfaces.swift` is read/depended
// on by every module implementer as the cross-module contract; keeping
// this framework import out of it means a reader of Interfaces.swift never
// has to reason about FoundationModels availability just to see the
// protocol shapes. `ExplainServiceProtocol` (in Interfaces.swift)
// references `PassageExplanation.PartiallyGenerated` by same-module type
// lookup, which does not require importing FoundationModels there.
//
// VERIFY(iOS26): exact macro spelling (`@Generable`, `@Guide`, the
// `.count(_:)` guide constraint, and the compiler-synthesized
// `PartiallyGenerated` nested type used by `ExplainServiceProtocol`) is
// written to the shape documented in architecture.md §5.4. If the shipping
// iOS 26 FoundationModels API differs, update this file and
// docs/01-architecture.md §5.4 together, per architecture §5's own rule —
// do not restructure around a guess.
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
