// M6
// Canned, delayed-streaming `ExplainServiceProtocol` conformer for M4
// SwiftUI previews and tests (docs/specs/M6-explain.md §8.2). No
// `FoundationModels` import: canned `PartiallyGenerated` snapshots are built
// via `ExplainContentBridge` (defined in `ExplainService.swift`, same
// module), so this file never has to spell a `FoundationModels` type name
// itself, per §0.1's "framework calls stay in ExplainService.swift /
// ExplainAvailabilityMapping.swift only" rule.
//
// NOTE for whoever wires `AppContainer` (M0): `LingoPod/App/MockServices.swift`
// already declares a placeholder `final class MockExplainService` that
// always throws `.notImplemented` (M0-scaffolding.md §6's "not bare
// fatalError() stubs" placeholder generation). That file is `LingoPod/App/*`
// and out of scope for M6 to edit. Since both types share the name
// `MockExplainService` in the same app target, the placeholder in
// `MockServices.swift` (its "Explain (M6)" `MARK`, roughly lines 102-121)
// must be deleted once this file lands, or the target will fail to compile
// on a duplicate type declaration — this mirrors the swap procedure that
// file's own header comment already documents ("Each later module deletes
// ... its corresponding mock as it lands the real service").
import Foundation

@MainActor
final class MockExplainService: ExplainServiceProtocol, TranslationFallbackProviding {

    /// Selects which canned behavior `explain()` produces. Defaults to a
    /// normal multi-step stream; construct with a specific case to preview/
    /// test one `ExplainError` state.
    enum Scenario: Sendable {
        case normalStream
        case guardrailed
        case busy
        case failed
    }

    var availability: ExplainAvailability
    var scenario: Scenario

    init(availability: ExplainAvailability = .ready, scenario: Scenario = .normalStream) {
        self.availability = availability
        self.scenario = scenario
    }

    func explain(
        passage: String,
        context: String,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language
    ) -> AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error> {
        let scenario = self.scenario
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch scenario {
                    case .normalStream:
                        try await Self.streamCannedExplanation(passage: passage, into: continuation)
                        continuation.finish()
                    case .guardrailed:
                        try await Task.sleep(for: .milliseconds(200))
                        continuation.finish(throwing: ExplainError.guardrailed)
                    case .busy:
                        try await Task.sleep(for: .milliseconds(200))
                        continuation.finish(throwing: ExplainError.busy)
                    case .failed:
                        try await Task.sleep(for: .milliseconds(200))
                        continuation.finish(throwing: ExplainError.failed)
                    }
                } catch is CancellationError {
                    // Consumer abandoned the stream; nothing to finish.
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func translateFallback(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try await Task.sleep(for: .milliseconds(150))
        return "[\(target.maximalIdentifier)] \(text)"
    }

    /// Yields successively more-complete `PartiallyGenerated` snapshots by
    /// bridging a sequence of increasingly-populated full
    /// `PassageExplanation` values through `ExplainContentBridge`. This
    /// mirrors the *source-order, cumulative* streaming shape `@Generable`
    /// fields are documented to produce (translation, then meaning, then
    /// grammarNotes, then idiomNotes) without guessing at an unverified API
    /// for constructing a snapshot with individual fields left `nil`
    /// (M6-explain.md §8.2's own VERIFY note flags this same uncertainty).
    private static func streamCannedExplanation(
        passage: String,
        into continuation: AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error>.Continuation
    ) async throws {
        // VERIFY(iOS26): assumes the compiler still synthesizes
        // `PassageExplanation`'s plain memberwise initializer alongside the
        // `@Generable` macro's additions. If the macro suppresses it, add an
        // explicit `init` to `PassageExplanation.swift` (flag for the M0
        // owner — that file is read-only for M6) or switch this mock to
        // building each step's `GeneratedContent` directly.
        let steps = [
            PassageExplanation(
                translation: "This is a canned translation of: \(passage)",
                meaning: "",
                grammarNotes: [],
                idiomNotes: []
            ),
            PassageExplanation(
                translation: "This is a canned translation of: \(passage)",
                meaning: "This canned meaning explains the passage in a couple of sentences, for preview purposes only.",
                grammarNotes: [],
                idiomNotes: []
            ),
            PassageExplanation(
                translation: "This is a canned translation of: \(passage)",
                meaning: "This canned meaning explains the passage in a couple of sentences, for preview purposes only.",
                grammarNotes: ["Example grammar note about verb tense, for preview purposes only."],
                idiomNotes: []
            ),
            PassageExplanation(
                translation: "This is a canned translation of: \(passage)",
                meaning: "This canned meaning explains the passage in a couple of sentences, for preview purposes only.",
                grammarNotes: ["Example grammar note about verb tense, for preview purposes only."],
                idiomNotes: ["Example idiom/register note, for preview purposes only."]
            ),
        ]

        for step in steps {
            try Task.checkCancellation()
            let snapshot = try ExplainContentBridge.partiallyGenerated(from: step)
            continuation.yield(snapshot)
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

// Same rationale as `ExplainService`'s conformance: `ExplainServiceProtocol`
// refines `Sendable`; the mock's mutable state is MainActor-serialized.
extension MockExplainService: @unchecked Sendable {}
