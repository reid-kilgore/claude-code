// M3
// Concrete `TranscriptProviderProtocol` conformance (architecture §5.2,
// declared in `LingoPod/App/Interfaces.swift`). Orchestrates feed-vs-on-device
// sourcing, persistence, single-flight concurrency, and the architecture
// §11.15 resume policy (docs/specs/M3-transcripts.md §7, amended by
// architecture §11.4/§11.7/§11.8/§11.15 -- see those sections' notes below
// for exactly where this file departs from the spec's literal text).
//
// `TranscriptProvider` is a plain (non-`@MainActor`) `actor`; `TranscriptHandle`
// is `@MainActor`. Every touch of a `handle` below therefore needs an
// explicit `await` -- construction, `.apply(...)`, and reading `.segments`/
// `.languageCode`/`.state`/`.progress` all cross that actor boundary.
import Foundation
import SwiftData
import LingoPodKit
import os

enum TranscriptProviderError: Error, Sendable {
    case episodeNotFound
}

actor TranscriptProvider: TranscriptProviderProtocol {

    // MARK: - Single-flight state (§7.5)

    private var activeEpisodeID: PersistentIdentifier?
    private var activeTask: Task<Void, Never>?
    /// Retained only while a job for it is in-flight (§8's handle-lifetime
    /// note); cleared once a job reaches `.complete`/`.failed`.
    private var activeHandle: TranscriptHandle?

    private let writer: TranscriptWriter
    private let engineFactory: @Sendable () -> TranscriptionEngine
    private let logger = Logger(subsystem: "com.lingopod.app", category: "Transcription")

    /// 30 minutes, per architecture §11.8's binding download-wait policy.
    private static let downloadWaitTimeout: TimeInterval = 30 * 60
    private static let downloadWaitPollInterval: Duration = .seconds(1)

    init(modelContainer: ModelContainer, engineFactory: @escaping @Sendable () -> TranscriptionEngine = { TranscriptionEngine() }) {
        self.writer = TranscriptWriter(modelContainer: modelContainer)
        self.engineFactory = engineFactory

        // M2's PlayerEngine posts this immediately before switching episodes
        // (LingoPod/Playback/PlayerEngine.swift); observing it lets us
        // cancel in-flight transcription even if nobody has re-called
        // `transcript(for:)` for the new episode yet (e.g. the overlay
        // isn't open). Runs for the lifetime of the app (TranscriptProvider
        // is a singleton owned by AppContainer).
        Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .playerEngineWillSwitchEpisode) {
                guard let outgoingID = notification.userInfo?["episodeID"] as? PersistentIdentifier else { continue }
                await self?.cancelIfActive(episodeID: outgoingID)
            }
        }
    }

    // MARK: - TranscriptProviderProtocol

    func transcript(for episodeID: PersistentIdentifier) async throws -> TranscriptHandle {
        if episodeID == activeEpisodeID, let handle = activeHandle {
            return handle
        }

        await cancelActiveJobIfNeeded(newEpisodeID: episodeID)

        guard let context = try await writer.fetchEpisodeContext(episodeID: episodeID) else {
            throw TranscriptProviderError.episodeNotFound
        }

        if let existing = try await writer.fetchExistingTranscript(episodeID: episodeID) {
            switch existing.state {
            case .complete:
                return await handleFromPersisted(existing: existing, progress: 1.0)
            case .failed:
                let progress = existing.segments.isEmpty ? 0 : progressFraction(endTime: existing.segments.last?.endTime, duration: context.duration)
                return await handleFromPersisted(existing: existing, progress: progress)
            case .partial where !existing.segments.isEmpty:
                // Architecture §11.15 (supersedes this spec's "always
                // restart from scratch" policy): a stale `.partial` row
                // with committed segments resumes rather than restarts.
                return try await resumeOrRestartOnDevice(episodeID: episodeID, context: context, existing: existing)
            case .pending, .partial:
                // Nothing durable to resume from (§7.1 step 5's original
                // fallback still applies here: discard, fall through to a
                // fresh start).
                try await writer.deleteTranscript(episodeID: episodeID)
            }
        }

        if let feedURL = context.feedTranscriptURL {
            return await startFeedPath(episodeID: episodeID, feedTranscriptURL: feedURL, feedTranscriptType: context.feedTranscriptType, context: context)
        }
        return try await startOnDevicePath(episodeID: episodeID, context: context, resume: nil, reuseTranscriptID: nil)
    }

    func invalidateAndRetranscribe(episodeID: PersistentIdentifier) async throws -> TranscriptHandle {
        await cancelActiveJobIfNeeded(newEpisodeID: episodeID)

        guard let context = try await writer.fetchEpisodeContext(episodeID: episodeID) else {
            throw TranscriptProviderError.episodeNotFound
        }

        // §7.4: cascade-deletes segments; always takes the on-device path
        // afterward regardless of `feedTranscriptURL`.
        try await writer.deleteTranscript(episodeID: episodeID)
        return try await startOnDevicePath(episodeID: episodeID, context: context, resume: nil, reuseTranscriptID: nil)
    }

    // MARK: - Cancellation (§7.5, §7.6 as amended by §11.15)

    private func cancelIfActive(episodeID: PersistentIdentifier) async {
        guard activeEpisodeID == episodeID, let task = activeTask else { return }
        logger.info("Cancelling in-flight transcription: episode switch (playerEngineWillSwitchEpisode).")
        task.cancel()
        await task.value
    }

    private func cancelActiveJobIfNeeded(newEpisodeID: PersistentIdentifier) async {
        guard let task = activeTask, activeEpisodeID != newEpisodeID else { return }
        logger.info("Cancelling in-flight transcription for a different episode before starting a new job.")
        task.cancel()
        await task.value
    }

    // MARK: - Feed path (§7.2)

    private func startFeedPath(episodeID: PersistentIdentifier, feedTranscriptURL: URL, feedTranscriptType: String?, context: EpisodeTranscriptionContext) async -> TranscriptHandle {
        let bestGuessLanguageCode = context.podcastLanguageOverride ?? context.podcastLanguageCode ?? "und"
        let handle = await TranscriptHandle(languageCode: bestGuessLanguageCode, state: .pending, segments: [], progress: 0)

        activeEpisodeID = episodeID
        activeHandle = handle

        let task = Task { [weak self] in
            await self?.runFeedJob(episodeID: episodeID, feedTranscriptURL: feedTranscriptURL, feedTranscriptType: feedTranscriptType, bestGuessLanguageCode: bestGuessLanguageCode, handle: handle)
        }
        activeTask = task
        return handle
    }

    private func runFeedJob(episodeID: PersistentIdentifier, feedTranscriptURL: URL, feedTranscriptType: String?, bestGuessLanguageCode: String, handle: TranscriptHandle) async {
        do {
            let transcriptID = try await writer.createPendingTranscript(episodeID: episodeID, source: .feed, languageCode: bestGuessLanguageCode)

            let data: Data
            do {
                let (fetched, response) = try await URLSession.shared.data(from: feedTranscriptURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw TranscriptProviderJobError.feedFetchFailed
                }
                data = fetched
            } catch {
                try Task.checkCancellation()
                try await fail(transcriptID: transcriptID, handle: handle, languageCode: bestGuessLanguageCode, code: .feedFetchFailed)
                clearActiveJob(episodeID: episodeID)
                return
            }

            try Task.checkCancellation()

            guard let format = TranscriptFormatSniffer.detect(mimeType: feedTranscriptType, url: feedTranscriptURL, data: data) else {
                try await fail(transcriptID: transcriptID, handle: handle, languageCode: bestGuessLanguageCode, code: .feedUnsupportedFormat)
                clearActiveJob(episodeID: episodeID)
                return
            }

            let cues: [RawTranscriptCue]
            do {
                switch format {
                case .srt:
                    cues = try SRTParser.parse(String(decoding: data, as: UTF8.self))
                case .vtt:
                    cues = try VTTParser.parse(String(decoding: data, as: UTF8.self))
                case .podcastIndexJSON:
                    cues = try PodcastIndexJSONTranscriptParser.parse(data)
                }
            } catch {
                try await fail(transcriptID: transcriptID, handle: handle, languageCode: bestGuessLanguageCode, code: .feedParseError)
                clearActiveJob(episodeID: episodeID)
                return
            }

            try Task.checkCancellation()

            let segments = SegmentNormalizer.normalize(cues: cues)
            let snapshots = try await writer.replaceAllSegments(segments, transcriptID: transcriptID, newState: .complete)
            await handle.apply(languageCode: bestGuessLanguageCode, state: .complete, segments: snapshots, progress: 1.0)
            clearActiveJob(episodeID: episodeID)
        } catch is CancellationError {
            // Expected on episode switch -- leave whatever was persisted
            // (likely nothing yet, since the feed path has no meaningful
            // partial phase) alone; just stop tracking it as active.
            clearActiveJob(episodeID: episodeID)
        } catch {
            logger.error("Unexpected error in feed transcription job: \(String(describing: error), privacy: .public)")
            clearActiveJob(episodeID: episodeID)
        }
    }

    // MARK: - On-device path (§7.3)

    private func startOnDevicePath(
        episodeID: PersistentIdentifier,
        context: EpisodeTranscriptionContext,
        resume: TranscriptionEngine.ResumeInfo?,
        reuseTranscriptID: PersistentIdentifier?,
        seedSegments: [TranscriptSegmentSnapshot] = []
    ) async throws -> TranscriptHandle {
        guard let requestedLanguage = LocaleResolver.normalizeBCP47(context.podcastLanguageOverride ?? context.podcastLanguageCode) else {
            let transcriptID = try await writer.createPendingTranscript(episodeID: episodeID, source: .onDevice, languageCode: "und")
            try await writer.setState(.failed(reason: TranscriptFailureCode.noLanguageSpecified.rawValue), transcriptID: transcriptID)
            return await TranscriptHandle(languageCode: "und", state: .failed(reason: TranscriptFailureCode.noLanguageSpecified.rawValue), segments: [], progress: 0)
        }

        let bestGuessLanguageCode = requestedLanguage.minimalIdentifier

        let transcriptID: PersistentIdentifier
        if let reuseTranscriptID {
            transcriptID = reuseTranscriptID
        } else {
            transcriptID = try await writer.createPendingTranscript(episodeID: episodeID, source: .onDevice, languageCode: bestGuessLanguageCode)
        }

        let progress = progressFraction(endTime: seedSegments.last?.endTime, duration: context.duration)
        let handle = await TranscriptHandle(
            languageCode: bestGuessLanguageCode,
            state: seedSegments.isEmpty ? .pending : .partial,
            segments: seedSegments,
            progress: progress
        )

        activeEpisodeID = episodeID
        activeHandle = handle

        let task = Task { [weak self] in
            await self?.runOnDeviceJob(episodeID: episodeID, transcriptID: transcriptID, context: context, resume: resume, requestedLanguage: requestedLanguage, handle: handle)
        }
        activeTask = task
        return handle
    }

    private func runOnDeviceJob(
        episodeID: PersistentIdentifier,
        transcriptID: PersistentIdentifier,
        context initialContext: EpisodeTranscriptionContext,
        resume: TranscriptionEngine.ResumeInfo?,
        requestedLanguage: Locale.Language,
        handle: TranscriptHandle
    ) async {
        do {
            var context = initialContext

            // §7.3 step 3 / architecture §11.8: wait for the episode to
            // finish downloading if it hasn't already.
            if context.downloadState != .downloaded {
                switch try await waitForDownload(episodeID: episodeID) {
                case .downloaded(let updated):
                    context = updated
                case .downloadFailed, .timedOut:
                    let currentLanguageCode = await handle.languageCode
                    try await fail(transcriptID: transcriptID, handle: handle, languageCode: currentLanguageCode, code: .needsDownload)
                    clearActiveJob(episodeID: episodeID)
                    return
                case .episodeGone:
                    clearActiveJob(episodeID: episodeID)
                    return
                }
            }

            try Task.checkCancellation()

            guard let audioURL = context.resolvedLocalAudioURL else {
                let currentLanguageCode = await handle.languageCode
                try await fail(transcriptID: transcriptID, handle: handle, languageCode: currentLanguageCode, code: .audioFileUnreadable)
                clearActiveJob(episodeID: episodeID)
                return
            }

            let supported = await TranscriptionEngine.supportedLocales()
            guard let resolvedLocale = LocaleResolver.resolve(requested: requestedLanguage, supported: supported) else {
                let currentLanguageCode = await handle.languageCode
                try await fail(transcriptID: transcriptID, handle: handle, languageCode: currentLanguageCode, code: .unsupportedLocale)
                clearActiveJob(episodeID: episodeID)
                return
            }

            // §5: "whichever [locale] is chosen gets written into
            // Transcript.languageCode as the actual locale used."
            let finalLanguageCode = resolvedLocale.identifier(.bcp47)
            try await writer.updateLanguageCode(finalLanguageCode, transcriptID: transcriptID)
            let currentState = await handle.state
            let currentSegments = await handle.segments
            let currentProgress = await handle.progress
            await handle.apply(languageCode: finalLanguageCode, state: currentState, segments: currentSegments, progress: currentProgress)

            try Task.checkCancellation()

            let engine = engineFactory()
            let input = TranscriptionEngine.Input(
                episodeID: episodeID,
                transcriptID: transcriptID,
                audioFileURL: audioURL,
                requestedLocale: resolvedLocale,
                episodeDurationHint: context.duration,
                resume: resume
            )

            // See `TranscriptionEngine.run`'s doc comment: an
            // `AsyncStream<ProgressUpdate>.Continuation`, not a closure
            // capturing `handle`, because `TranscriptHandle` is a
            // `@MainActor` class and therefore not `Sendable`. This loop
            // (plain sequential code in this actor's own async context, not
            // a `@Sendable` closure) is the only place that touches
            // `handle` while the engine runs.
            let (stream, continuation) = AsyncStream<TranscriptionEngine.ProgressUpdate>.makeStream()
            async let engineRun: Void = engine.run(input, writer: writer, updates: continuation)

            for await update in stream {
                let existingSegments = await handle.segments
                let merged = update.newSegments.isEmpty ? existingSegments : existingSegments + update.newSegments
                await handle.apply(languageCode: finalLanguageCode, state: update.state, segments: merged, progress: update.progress)
            }

            try await engineRun
            clearActiveJob(episodeID: episodeID)
        } catch is CancellationError {
            // §7.6 (as amended by §11.15): leave the persisted row exactly
            // as it last was (`.pending` or `.partial`, whatever the engine
            // last committed) -- never mark `.failed` on cancellation, and
            // never delete it either, since a future `transcript(for:)`
            // call may resume it.
            clearActiveJob(episodeID: episodeID)
        } catch let engineError as TranscriptionEngineError {
            let code: TranscriptFailureCode
            switch engineError {
            case .audioFileUnreadable: code = .audioFileUnreadable
            case .assetDownloadFailed: code = .assetDownloadFailed
            case .assetDownloadNoNetwork: code = .assetDownloadNoNetwork
            case .analyzerError: code = .analyzerError
            }
            let currentLanguageCode = await handle.languageCode
            try? await fail(transcriptID: transcriptID, handle: handle, languageCode: currentLanguageCode, code: code)
            clearActiveJob(episodeID: episodeID)
        } catch {
            logger.error("Unexpected error in on-device transcription job: \(String(describing: error), privacy: .public)")
            let currentLanguageCode = await handle.languageCode
            try? await fail(transcriptID: transcriptID, handle: handle, languageCode: currentLanguageCode, code: .analyzerError)
            clearActiveJob(episodeID: episodeID)
        }
    }

    // MARK: - §11.15 resume decision

    private func resumeOrRestartOnDevice(episodeID: PersistentIdentifier, context: EpisodeTranscriptionContext, existing: ExistingTranscriptInfo) async throws -> TranscriptHandle {
        // Full re-transcription (not resume) if the resolved locale has
        // changed since this transcript was created, or if the prior
        // transcript wasn't itself on-device sourced. (Audio-file-change
        // detection -- the other §11.15 trigger -- isn't possible with the
        // current persisted schema, which has no content hash/identity
        // field for the audio file; treated as always-unchanged. See M3
        // report deviations.)
        guard existing.source == .onDevice, localeMatches(existing.languageCode, context: context) else {
            try await writer.deleteTranscript(episodeID: episodeID)
            return try await startOnDevicePath(episodeID: episodeID, context: context, resume: nil, reuseTranscriptID: nil)
        }

        guard let lastSegment = existing.segments.max(by: { $0.index < $1.index }) else {
            try await writer.deleteTranscript(episodeID: episodeID)
            return try await startOnDevicePath(episodeID: episodeID, context: context, resume: nil, reuseTranscriptID: nil)
        }

        let resume = TranscriptionEngine.ResumeInfo(lastSegmentEndTime: lastSegment.endTime, nextSegmentIndex: lastSegment.index + 1)
        return try await startOnDevicePath(
            episodeID: episodeID,
            context: context,
            resume: resume,
            reuseTranscriptID: existing.transcriptID,
            seedSegments: existing.segments
        )
    }

    /// Best-effort check: does `persistedLanguageCode` (the actually-resolved
    /// locale identifier written by a prior run, or the pre-match best-guess
    /// if that run never got past locale resolution) still match what would
    /// be resolved *today* from the podcast's current language settings?
    private func localeMatches(_ persistedLanguageCode: String, context: EpisodeTranscriptionContext) -> Bool {
        guard let requested = LocaleResolver.normalizeBCP47(context.podcastLanguageOverride ?? context.podcastLanguageCode) else {
            return false
        }
        guard let persisted = LocaleResolver.normalizeBCP47(persistedLanguageCode) else {
            return false
        }
        return requested.languageCode == persisted.languageCode
    }

    // MARK: - Download watcher (architecture §11.8)

    private enum WaitForDownloadResult {
        case downloaded(EpisodeTranscriptionContext)
        case downloadFailed
        case timedOut
        case episodeGone
    }

    private func waitForDownload(episodeID: PersistentIdentifier) async throws -> WaitForDownloadResult {
        let deadline = Date().addingTimeInterval(Self.downloadWaitTimeout)
        while true {
            try Task.checkCancellation()
            guard let context = try await writer.fetchEpisodeContext(episodeID: episodeID) else {
                return .episodeGone
            }
            switch context.downloadState {
            case .downloaded:
                return .downloaded(context)
            case .failed:
                return .downloadFailed
            case .none, .inProgress:
                if Date() >= deadline {
                    return .timedOut
                }
                try await Task.sleep(for: Self.downloadWaitPollInterval)
            }
        }
    }

    // MARK: - Shared helpers

    private func fail(transcriptID: PersistentIdentifier, handle: TranscriptHandle, languageCode: String, code: TranscriptFailureCode) async throws {
        try await writer.setState(.failed(reason: code.rawValue), transcriptID: transcriptID)
        let currentSegments = await handle.segments
        let currentProgress = await handle.progress
        await handle.apply(languageCode: languageCode, state: .failed(reason: code.rawValue), segments: currentSegments, progress: currentProgress)
    }

    private func clearActiveJob(episodeID: PersistentIdentifier) {
        guard activeEpisodeID == episodeID else { return }
        activeEpisodeID = nil
        activeTask = nil
        activeHandle = nil
    }

    private func handleFromPersisted(existing: ExistingTranscriptInfo, progress: Double) async -> TranscriptHandle {
        await TranscriptHandle(languageCode: existing.languageCode, state: existing.state, segments: existing.segments, progress: progress)
    }

    private func progressFraction(endTime: TimeInterval?, duration: TimeInterval?) -> Double {
        guard let endTime, let duration, duration > 0 else { return 0 }
        return min(1.0, max(0.0, endTime / duration))
    }
}

/// Internal, engine-job-local error used only to short-circuit the feed
/// path's do/catch (never escapes `runFeedJob`).
private enum TranscriptProviderJobError: Error {
    case feedFetchFailed
}
