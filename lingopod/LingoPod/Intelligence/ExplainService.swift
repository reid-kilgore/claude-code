// M6
// Concrete `ExplainServiceProtocol` implementation. This is the one "thin
// file" (alongside `ExplainAvailabilityMapping.swift`) where
// `FoundationModels` calls live for the tutor explain flow
// (docs/specs/M6-explain.md §0.1): session lifecycle, prompt dispatch,
// `streamResponse` iteration, `GenerationError` mapping, single-in-flight
// cancellation, and cache orchestration all happen here. Everything else in
// the app (M4, previews, tests) only ever sees `ExplainServiceProtocol` /
// `TranslationFallbackProviding` / `ExplainError`, never
// `LanguageModelSession` or `GenerationError` directly.
import Foundation
import FoundationModels
import os
import LingoPodKit

// MARK: - Errors surfaced to callers (never `LanguageModelSession.GenerationError`)

/// User-facing error vocabulary for anything touching `ExplainService`
/// (M6-explain.md §4.1, §6). M4 pattern-matches on these without needing to
/// know `LanguageModelSession.GenerationError`'s real shape.
enum ExplainError: Error, Equatable, Sendable {
    /// Guardrail violation — do not retry. Copy: "Couldn't analyze this
    /// passage."
    case guardrailed
    /// Rate limited — do not retry immediately. Copy: "Explain is briefly
    /// busy — try again in a moment."
    case busy
    /// Any other failure (including a double context-window failure, or an
    /// unknown/unmapped error). Copy: "Couldn't analyze this passage."
    case failed
}

// MARK: - Session keying (M6-explain.md §2.1)

struct LanguagePairKey: Hashable, Sendable {
    let source: String   // Locale.Language.maximalIdentifier
    let target: String
}

// MARK: - Translation-fallback structured result (M6-explain.md §6)

@Generable
struct TranslationFallbackResult {
    @Guide(description: "Direct translation of the input text into the target language, and nothing else")
    var translation: String
}

// MARK: - Cache-hit / mock bridging helper

/// Bridges a fully-generated `PassageExplanation` into the
/// `PartiallyGenerated` stream-element type `ExplainServiceProtocol.explain`
/// must always return, even when there's no live generation happening
/// (cache hits, §5.3; canned mock scenarios, §8.2's `MockExplainService`).
///
/// Exposed at file scope (default `internal` access, not `private`) so
/// `MockExplainService.swift` can build its own canned snapshots through
/// this same bridge without itself importing `FoundationModels` — the call
/// site there only ever spells `PassageExplanation` /
/// `PassageExplanation.PartiallyGenerated`, both of which are visible
/// same-module without the import (see the note in `Interfaces.swift` about
/// `PassageExplanation.PartiallyGenerated` being a same-module type
/// reference).
enum ExplainContentBridge {
    // VERIFY(iOS26): `PassageExplanation` conforms to `Generable`, which is
    // expected to expose its content as `GeneratedContent` (commonly a
    // `.generatedContent` computed property), and `PartiallyGenerated` is
    // expected to be constructible from `GeneratedContent` (M6-explain.md
    // §5.3's primary approach). If this turns out not to compile against
    // the real SDK (no such initializer exists), fall back to §5.3's
    // secondary approach (`ExplainService.lastCacheHit`) instead of
    // guessing further here.
    static func partiallyGenerated(from value: PassageExplanation) throws -> PassageExplanation.PartiallyGenerated {
        try PassageExplanation.PartiallyGenerated(value.generatedContent)
    }
}

@MainActor
final class ExplainService: ExplainServiceProtocol, TranslationFallbackProviding {

    private let logger = Logger(subsystem: "com.lingopod.app", category: "M6")

    // MARK: Availability (M6-explain.md §1)

    private(set) var availability: ExplainAvailability

    /// Re-reads `SystemLanguageModel.default.availability` and updates
    /// `availability` if it changed. Not part of `ExplainServiceProtocol`
    /// (§1.4) — the root scene (M0) calls this on `scenePhase` transitioning
    /// to `.active`, and once at `AppContainer` construction time; safe to
    /// call at any time. No automatic timer polling.
    func refreshAvailability() {
        let mapped = mapAvailability(SystemLanguageModel.default.availability)
        if mapped != availability {
            availability = mapped
        }
    }

    // MARK: Session lifecycle (§2.1, §2.2)

    private var sessions: [LanguagePairKey: LanguageModelSession] = [:]
    private var translationFallbackSessions: [LanguagePairKey: LanguageModelSession] = [:]

    private func session(source: Locale.Language, target: Locale.Language) -> LanguageModelSession {
        let key = LanguagePairKey(source: source.maximalIdentifier, target: target.maximalIdentifier)
        if let existing = sessions[key] {
            return existing
        }
        let instructionsText = ExplainPrompting.makeInstructions(sourceLanguage: source, targetLanguage: target)
        // VERIFY(iOS26): confirm initializer shape — see M6-explain.md §2.1.
        // Kept isolated to this one line so a future API-shape correction
        // touches only this call site.
        let session = LanguageModelSession(instructions: instructionsText)
        sessions[key] = session
        return session
    }

    private func evictSession(source: Locale.Language, target: Locale.Language) {
        let key = LanguagePairKey(source: source.maximalIdentifier, target: target.maximalIdentifier)
        sessions.removeValue(forKey: key)
    }

    /// M4 calls this when the overlay's explain affordance becomes
    /// visible/active (e.g. on selection start), not on every keystroke
    /// (M6-explain.md §2.2).
    func prewarm(sourceLanguage: Locale.Language, targetLanguage: Locale.Language) {
        let modelSession = session(source: sourceLanguage, target: targetLanguage)
        // VERIFY(iOS26): confirm `LanguageModelSession.prewarm()`'s exact
        // no-arg signature.
        modelSession.prewarm()
    }

    // MARK: Cache (§5)

    private let cacheStore: ExplanationCacheStore

    /// Secondary cache-hit fallback surface (§5.3) — only meaningfully
    /// populated if `ExplainContentBridge.partiallyGenerated(from:)` (the
    /// primary approach, used below) turns out not to compile against the
    /// real SDK and this file is revised to use the fallback path instead.
    /// Left in place now so the seam exists either way; M4's integration
    /// notes document checking this after a zero-element stream.
    private(set) var lastCacheHit: PassageExplanation?

    // MARK: Single in-flight generation (§4.2)

    private var currentGenerationID: UUID?
    private var currentTask: Task<Void, Never>?

    // MARK: Init

    init(cacheStore: ExplanationCacheStore) {
        self.cacheStore = cacheStore
        self.availability = mapAvailability(SystemLanguageModel.default.availability)
    }

    // MARK: ExplainServiceProtocol

    func explain(
        passage: String,
        context: String,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language
    ) -> AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error> {
        // §4.2: only one generation in flight at a time, across all
        // language pairs. Cancel cooperatively; do not block on teardown.
        currentTask?.cancel()

        let generationID = UUID()
        currentGenerationID = generationID

        // Passage is never re-trimmed here (§3.2) — M4 enforces the
        // ≤280-character cap before calling `explain()`. Log (no content)
        // if it arrives unexpectedly long.
        if passage.utf16.count > 280 {
            logger.warning("explain() received a passage longer than the expected 280-character cap")
        }

        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                await self?.runExplain(
                    passage: passage,
                    context: context,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    generationID: generationID,
                    continuation: continuation
                )
            }
            self.currentTask = task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Internal generation pipeline

    private func isCurrent(_ generationID: UUID) -> Bool {
        currentGenerationID == generationID
    }

    private func runExplain(
        passage: String,
        context: String,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language,
        generationID: UUID,
        continuation: AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error>.Continuation
    ) async {
        let key = ExplainPrompting.cacheKey(
            passage: passage, context: context,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage
        )

        // §5.2: cache check first, before touching LanguageModelSession at
        // all.
        if let cached = try? await cacheStore.fetch(key: key) {
            await emitCacheHit(cached, generationID: generationID, continuation: continuation)
            return
        }

        await streamGeneration(
            passage: passage, context: context,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
            cacheKey: key, contextOverride: nil, isRetry: false,
            generationID: generationID, continuation: continuation
        )
    }

    private func emitCacheHit(
        _ cached: ExplanationCacheRecord,
        generationID: UUID,
        continuation: AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error>.Continuation
    ) async {
        guard isCurrent(generationID) else { return }
        do {
            // VERIFY(iOS26): assumes `PassageExplanation` is `Codable` (it
            // is stored as JSON `Data` per `ExplanationCacheEntry` /
            // architecture §4). `PassageExplanation.swift` is M0-owned and
            // read-only for M6; if `@Generable` does not itself synthesize
            // `Codable` conformance in the shipping SDK, that file needs an
            // explicit `: Codable` added — flagged for the M0 owner rather
            // than edited here.
            let full = try JSONDecoder().decode(PassageExplanation.self, from: cached.explanationJSON)
            let snapshot = try ExplainContentBridge.partiallyGenerated(from: full)
            guard isCurrent(generationID) else { return }
            continuation.yield(snapshot)
            continuation.finish()
        } catch {
            logger.error("Cache hit decode/bridge failed: \(String(describing: error), privacy: .public)")
            guard isCurrent(generationID) else { return }
            continuation.finish(throwing: ExplainError.failed)
        }
    }

    private func streamGeneration(
        passage: String,
        context: String,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language,
        cacheKey: String,
        contextOverride: String?,
        isRetry: Bool,
        generationID: UUID,
        continuation: AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error>.Continuation
    ) async {
        guard isCurrent(generationID) else { return }

        let effectiveContext = contextOverride ?? context
        let promptText = ExplainPrompting.makePrompt(
            passage: passage, context: effectiveContext,
            sourceLanguage: sourceLanguage, targetLanguage: targetLanguage
        )
        let modelSession = session(source: sourceLanguage, target: targetLanguage)

        do {
            // VERIFY(iOS26): confirm exact call shape — see M6-explain.md
            // §3.3. `responseStream`'s elements are expected to be
            // `PassageExplanation.PartiallyGenerated` cumulative snapshots.
            let responseStream = modelSession.streamResponse(to: promptText, generating: PassageExplanation.self)
            var lastSnapshot: PassageExplanation.PartiallyGenerated?
            for try await partial in responseStream {
                guard isCurrent(generationID) else { return }
                lastSnapshot = partial
                continuation.yield(partial)
            }
            guard isCurrent(generationID) else { return }
            guard let lastSnapshot else {
                continuation.finish(throwing: ExplainError.failed)
                return
            }
            // VERIFY(iOS26): the last streamed snapshot is expected to have
            // every field populated but is still typed as
            // `PartiallyGenerated`; FoundationModels is expected to offer a
            // way to obtain the final concrete `PassageExplanation` from it
            // (§5.4). Kept isolated to this one line.
            let finalValue = try PassageExplanation(lastSnapshot)
            await writeCache(key: cacheKey, passage: passage, value: finalValue, generationID: generationID)
            guard isCurrent(generationID) else { return }
            continuation.finish()
        } catch is CancellationError {
            // Superseded by a newer explain() call (§4.2) — this
            // continuation's consumer has already moved on to the newer
            // call's stream; do not finish it (finishing here would be a
            // stale/duplicate signal on an abandoned stream).
            return
        } catch let error as LanguageModelSession.GenerationError {
            await handleGenerationError(
                error,
                passage: passage, context: context,
                sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                cacheKey: cacheKey, isRetry: isRetry,
                generationID: generationID, continuation: continuation
            )
        } catch {
            logger.error("Unexpected explain() error: \(String(describing: error), privacy: .public)")
            guard isCurrent(generationID) else { return }
            continuation.finish(throwing: ExplainError.failed)
        }
    }

    private func handleGenerationError(
        _ error: LanguageModelSession.GenerationError,
        passage: String,
        context: String,
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language,
        cacheKey: String,
        isRetry: Bool,
        generationID: UUID,
        continuation: AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error>.Continuation
    ) async {
        guard isCurrent(generationID) else { return }

        switch error {
        case .guardrailViolation:
            logger.notice("Explain guardrail violation")
            continuation.finish(throwing: ExplainError.guardrailed)

        case .exceededContextWindowSize:
            guard !isRetry else {
                // §4.3: never retry more than once. A second failure, even
                // passage-only, surfaces as a normal failure.
                logger.notice("Explain exceeded context window on passage-only retry; giving up")
                continuation.finish(throwing: ExplainError.failed)
                return
            }
            logger.notice("Explain exceeded context window; evicting session and retrying passage-only once")
            evictSession(source: sourceLanguage, target: targetLanguage)
            await streamGeneration(
                passage: passage, context: context,
                sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                cacheKey: cacheKey, contextOverride: "", isRetry: true,
                generationID: generationID, continuation: continuation
            )

        case .rateLimited:
            logger.notice("Explain rate limited")
            continuation.finish(throwing: ExplainError.busy)

        default:
            logger.error("Explain generation error: \(String(describing: error), privacy: .public)")
            continuation.finish(throwing: ExplainError.failed)
        }
    }

    private func writeCache(
        key: String,
        passage: String,
        value: PassageExplanation,
        generationID: UUID
    ) async {
        guard isCurrent(generationID) else { return }
        do {
            let json = try JSONEncoder().encode(value)
            try await cacheStore.upsert(key: key, passage: passage, explanationJSON: json)
        } catch {
            logger.error("Explain cache write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - TranslationFallbackProviding (M6-explain.md §6)

extension ExplainService {
    func translateFallback(
        text: String,
        from source: Locale.Language,
        to target: Locale.Language
    ) async throws -> String {
        let key = LanguagePairKey(source: source.maximalIdentifier, target: target.maximalIdentifier)
        let modelSession: LanguageModelSession
        if let existing = translationFallbackSessions[key] {
            modelSession = existing
        } else {
            let instructionsText = ExplainPrompting.makeTranslationFallbackInstructions(
                sourceLanguage: source, targetLanguage: target
            )
            let newSession = LanguageModelSession(instructions: instructionsText)
            translationFallbackSessions[key] = newSession
            modelSession = newSession
        }

        do {
            // VERIFY(iOS26): prefer a non-streaming single-shot API if
            // FoundationModels offers one (`respond(to:generating:)`),
            // since this is a short single-field result with no card UI to
            // fill in incrementally (§6).
            let result = try await modelSession.respond(to: text, generating: TranslationFallbackResult.self)
            return result.content.translation
        } catch let error as LanguageModelSession.GenerationError {
            throw mapTranslateFallbackError(error)
        } catch {
            logger.error("translateFallback unexpected error: \(String(describing: error), privacy: .public)")
            throw ExplainError.failed
        }
    }

    private func mapTranslateFallbackError(_ error: LanguageModelSession.GenerationError) -> ExplainError {
        switch error {
        case .guardrailViolation:
            return .guardrailed
        case .rateLimited:
            return .busy
        default:
            return .failed
        }
    }
}
