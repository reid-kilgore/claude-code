// M5
// Adapts SwiftUI's view-lifecycle-scoped `.translationTask` API to the
// plain `async throws -> String` shape `TranslationServiceProtocol`
// promises (architecture §5.3; docs/specs/M5-translation.md §3). See
// `TranslationHostView` for the other half of the bridge, and §3.2 of the
// spec for the "@MainActor @Observable, not actor" decision this class
// follows.
import Foundation
import Observation
import Translation
import os

@MainActor
@Observable
final class TranslationService: TranslationServiceProtocol, TranslationDownloadPreparing {
    /// Read directly by `TranslationHostView`'s `.translationTask`
    /// modifier (spec §3.1) — not a separate `@State` copy, so there is
    /// exactly one source of truth for "what language pair is active."
    private(set) var pendingConfiguration: TranslationSession.Configuration?

    private var queue: [PendingTranslationRequest] = []
    private var continuations: [UUID: CheckedContinuation<String, Error>] = [:]
    /// The pair whose `run(session:)` loop is currently live.
    private var activePair: LanguagePair?
    /// The pair `activateConfigurationIfNeeded` most recently set
    /// `pendingConfiguration` for, set in lockstep with it. `run(session:)`
    /// reads this to learn which pair the session SwiftUI just handed it
    /// belongs to, rather than asking the session itself — see the
    /// VERIFY(iOS26) note at that call site.
    private var configuredPair: LanguagePair?
    private var currentSession: TranslationSessionProtocol?
    private var sessionWaiters: [LanguagePair: [CheckedContinuation<TranslationSessionProtocol, Never>]] = [:]
    private var pendingWork: Set<LanguagePair> = []
    private var workWaiters: [LanguagePair: CheckedContinuation<Void, Never>] = [:]

    private let cache: TranslationCacheStore
    private let availabilityChecker: LanguageAvailabilityChecking
    private let networkMonitor: NetworkReachabilityChecking
    private let sleeper: @Sendable (Duration) async -> Void
    private let coalesceWindow: Duration = .milliseconds(100)
    private let maxBatchSize = 20
    private let logger = Logger(subsystem: "com.lingopod.app", category: "Translation")

    init(
        cache: TranslationCacheStore,
        availabilityChecker: LanguageAvailabilityChecking = LiveLanguageAvailability(),
        networkMonitor: NetworkReachabilityChecking = TranslationNetworkMonitor(),
        sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.cache = cache
        self.availabilityChecker = availabilityChecker
        self.networkMonitor = networkMonitor
        self.sleeper = sleeper
    }

    // MARK: - TranslationServiceProtocol

    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        guard !isSameLanguage(source, target) else {
            logger.debug("translate: sameLanguage guard fired, no-op")
            throw TranslationError.sameLanguage
        }

        let sourceID = source.minimalIdentifier
        let targetID = target.minimalIdentifier
        let key = TranslationCacheKey.make(text: text, source: sourceID, target: targetID)

        if let cached = await cache.lookup(key: key) {
            return cached
        }

        switch await availability(from: source, to: target) {
        case .unsupported:
            throw TranslationError.unsupportedLanguagePair
        case .needsDownload:
            throw TranslationError.languagePackNeedsDownload
        case .ready:
            break
        }

        let pair = LanguagePair(source: source, target: target)
        let translated = try await enqueueAndAwait(text: text, pair: pair)

        await cache.store(
            key: key,
            sourceText: text,
            translatedText: translated,
            sourceLanguage: sourceID,
            targetLanguage: targetID
        )
        return translated
    }

    func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
        switch await availabilityChecker.status(from: source, to: target) {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        }
    }

    // MARK: - TranslationDownloadPreparing

    func prepare(from source: Locale.Language, to target: Locale.Language) async throws {
        guard await availability(from: source, to: target) != .unsupported else {
            throw TranslationError.unsupportedLanguagePair
        }
        guard networkMonitor.isSatisfied else {
            throw TranslationError.downloadRequiresNetwork
        }

        let pair = LanguagePair(source: source, target: target)
        activateConfigurationIfNeeded(for: pair)
        let adapter = await waitForSession(matching: pair)
        do {
            try await adapter.prepareTranslation()
        } catch {
            logger.error("prepareTranslation failed: \(String(describing: error), privacy: .public)")
            throw TranslationError.sessionUnavailable(reason: String(describing: error))
        }
    }

    // MARK: - Host loop entry point (called by TranslationHostView, §3.4)

    func run(session: TranslationSession) async {
        let adapter = LiveTranslationSession(session: session)
        // VERIFY(iOS26): confirm whether `TranslationSession` exposes its
        // resolved source/target languages directly (e.g.
        // `session.sourceLanguage`/`.targetLanguage`); if so this could
        // read them instead of `configuredPair`. As written, `configuredPair`
        // (set in lockstep with `pendingConfiguration` by
        // `activateConfigurationIfNeeded`) is used instead, since it is
        // guaranteed correct regardless of that API's exact shape — this is
        // the side-table fallback the spec calls out.
        guard let pair = configuredPair else {
            logger.error("run(session:) invoked with no known pair; ignoring")
            return
        }
        await runQueueLoop(pair: pair, adapter: adapter)
    }

    /// The queue-draining loop for one active (pair, session) — internal
    /// (not `private`) so `TranslationQueueTests` can drive it directly
    /// with a `MockTranslationSession`, bypassing the real
    /// `TranslationSession` that only `.translationTask` can produce.
    func runQueueLoop(pair: LanguagePair, adapter: TranslationSessionProtocol) async {
        activePair = pair
        currentSession = adapter
        resumeWaiters(for: pair, with: adapter)

        await withTaskCancellationHandler {
            while !Task.isCancelled {
                await waitForWork(on: pair)
                guard !Task.isCancelled else { break }
                await sleeper(coalesceWindow)
                guard !Task.isCancelled else { break }
                await flush(pair: pair, using: adapter)
            }
        } onCancel: { [logger] in
            // Requests still queued for this pair when cancelled are left
            // in `queue` (§3.4) — not failed here; if the same pair
            // becomes active again later they'll be served then. Only fail
            // them if the service itself is torn down, which is not
            // expected during normal app lifetime.
            logger.debug("translation host loop cancelled")
        }

        if activePair == pair {
            activePair = nil
            currentSession = nil
        }
    }

    // MARK: - Queue plumbing

    /// Enqueues `text` for translation under `pair` and suspends until a
    /// batch flush resolves it. Kept separate from `translate(_:from:to:)`
    /// so tests can exercise pure queue/coalescing behavior without a real
    /// `TranslationCacheStore`/`LanguageAvailabilityChecking` in the loop —
    /// callers still go through `translate(_:from:to:)` for cache/
    /// availability checks.
    private func enqueueAndAwait(text: String, pair: LanguagePair) async throws -> String {
        activateConfigurationIfNeeded(for: pair)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let id = UUID()
            queue.append(PendingTranslationRequest(id: id, text: text, pair: pair))
            continuations[id] = continuation
            scheduleFlush(for: pair)
        }
    }

    /// Sets `pendingConfiguration` (restarting `TranslationHostView`'s
    /// `.translationTask`) only if a different pair than the currently
    /// active one is requested (spec §3.3). If `activePair == pair`
    /// already, the running `run(session:)` loop for that pair will pick
    /// up the newly-queued request on its next wake.
    private func activateConfigurationIfNeeded(for pair: LanguagePair) {
        guard activePair != pair else { return }
        configuredPair = pair
        // VERIFY(iOS26): confirm `TranslationSession.Configuration`'s
        // memberwise initializer is `(source:target:)` taking
        // `Locale.Language`/`Locale.Language?`. Documented shape as of this
        // writing.
        pendingConfiguration = TranslationSession.Configuration(source: pair.source, target: pair.target)
    }

    private func scheduleFlush(for pair: LanguagePair) {
        if let waiter = workWaiters.removeValue(forKey: pair) {
            waiter.resume()
        } else {
            pendingWork.insert(pair)
        }
    }

    private func waitForWork(on pair: LanguagePair) async {
        if pendingWork.remove(pair) != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            workWaiters[pair] = continuation
        }
    }

    /// Drains up to `maxBatchSize` queued requests matching `pair`, calls
    /// `adapter.performBatch(_:)`, and resumes the corresponding
    /// continuations with the result or the error. Does not touch the
    /// cache — the caller side (`translate`) writes through on success.
    private func flush(pair: LanguagePair, using adapter: TranslationSessionProtocol) async {
        let batch = drainBatch(for: pair)
        guard !batch.isEmpty else { return }

        do {
            let results = try await adapter.performBatch(batch)
            for request in batch {
                guard let continuation = continuations.removeValue(forKey: request.id) else { continue }
                if let text = results[request.id.uuidString] {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(
                        throwing: TranslationError.sessionUnavailable(
                            reason: "missing response for request \(request.id)"
                        )
                    )
                }
            }
        } catch {
            logger.error("performBatch failed: \(String(describing: error), privacy: .public)")
            for request in batch {
                guard let continuation = continuations.removeValue(forKey: request.id) else { continue }
                continuation.resume(throwing: error)
            }
        }

        // More than maxBatchSize was queued: immediately schedule another
        // flush for the remainder rather than growing a single batch
        // unbounded (spec §3.3).
        if queue.contains(where: { $0.pair == pair }) {
            scheduleFlush(for: pair)
        }
    }

    private func drainBatch(for pair: LanguagePair) -> [PendingTranslationRequest] {
        var batch: [PendingTranslationRequest] = []
        var remaining: [PendingTranslationRequest] = []
        for request in queue {
            if request.pair == pair, batch.count < maxBatchSize {
                batch.append(request)
            } else {
                remaining.append(request)
            }
        }
        queue = remaining
        return batch
    }

    private func waitForSession(matching pair: LanguagePair) async -> TranslationSessionProtocol {
        if let currentSession, activePair == pair {
            return currentSession
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<TranslationSessionProtocol, Never>) in
            sessionWaiters[pair, default: []].append(continuation)
        }
    }

    private func resumeWaiters(for pair: LanguagePair, with adapter: TranslationSessionProtocol) {
        guard let waiters = sessionWaiters.removeValue(forKey: pair) else { return }
        for waiter in waiters {
            waiter.resume(returning: adapter)
        }
    }

    /// Compares `languageCode` only, deliberately ignoring script/region —
    /// e.g. `fr-FR` vs `fr-CA` still counts as "same language" here (spec
    /// §4).
    private func isSameLanguage(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode?.identifier == b.languageCode?.identifier
    }
}

// TranslationServiceProtocol requires Sendable. Swift does not synthesize
// Sendable for classes (even @MainActor ones) as of the Swift 6 language
// mode this project targets, so conformance must be declared explicitly.
// This is safe because every stored mutable property above is only ever
// touched while isolated to the main actor — there is no unsynchronized
// state. // VERIFY(iOS26): if a future toolchain accepts @MainActor
// classes as implicitly Sendable, drop the @unchecked and this comment.
extension TranslationService: @unchecked Sendable {}
