// M3
// Actor wrapping one `SpeechAnalyzer`/`SpeechTranscriber` pair for on-device
// transcription of a downloaded episode's audio file (docs/specs/
// M3-transcripts.md §6). Not a long-lived singleton pump -- `TranscriptProvider`
// creates one instance per transcription attempt. Orchestration (locale is
// pre-resolved by the caller → asset install → analyze → batch → persist)
// lives here; the direct Speech/AVFoundation framework calls are isolated in
// `SpeechTranscribing.swift` (same actor, separate file, per architecture §9).
import Foundation
import AVFoundation
import CoreMedia
import Speech
import LingoPodKit
import os

// MARK: - Errors (§6, §9's failure taxonomy feeds these into TranscriptFailureCode)

enum TranscriptionEngineError: Error, Sendable {
    case audioFileUnreadable(underlying: String)
    case assetDownloadFailed(underlying: String)
    case assetDownloadNoNetwork(underlying: String)
    case analyzerError(underlying: String)
}

actor TranscriptionEngine {

    // MARK: - Input (§6.1)

    struct Input: Sendable {
        var episodeID: PersistentIdentifier
        /// Pre-created `Transcript` row, state == `.pending` (fresh run) or
        /// `.partial` (§11.15 resume, reusing the prior row).
        var transcriptID: PersistentIdentifier
        var audioFileURL: URL
        /// Already resolved against `SpeechTranscriber.supportedLocales` by
        /// the caller (`TranscriptProvider`, §7.3 step 4) -- the engine
        /// trusts it. (Deviation from the spec's literal `Locale.Language`
        /// field type: `SpeechTranscriber(locale:)` needs a concrete
        /// `Locale`, per §6.4's own code sample and the feasibility spike;
        /// see M3 report.)
        var requestedLocale: Locale
        /// `Episode.duration` if known; else progress reporting degrades to
        /// 0 (no crash -- §6.8 guards the division).
        var episodeDurationHint: TimeInterval?
        /// Non-nil only for an architecture §11.15 resume.
        var resume: ResumeInfo?
    }

    /// §11.15: "feed audio to the analyzer starting at `lastSegment.endTime
    /// - 2s`, drop newly produced segments that end before
    /// `lastSegment.endTime`, continue appending."
    struct ResumeInfo: Sendable {
        var lastSegmentEndTime: TimeInterval
        var nextSegmentIndex: Int
    }

    /// Emitted once per committed batch (§6.8) and once more at the very
    /// end (§6.9's `.complete` transition). `TranscriptProvider` (which
    /// owns the `@MainActor` `TranscriptHandle`) applies these; the engine
    /// itself never touches `TranscriptHandle` (kept `@MainActor`-free so
    /// this actor stays a plain background actor per architecture §7).
    struct ProgressUpdate: Sendable {
        var newSegments: [TranscriptSegmentSnapshot]
        var state: TranscriptState
        var progress: Double
    }

    private let logger = Logger(subsystem: "com.lingopod.app", category: "Transcription")

    /// Runs one full transcription attempt end-to-end: asset→analyze→
    /// persist. Throws only for conditions the caller (`TranscriptProvider`)
    /// turns into a `TranscriptFailureCode`; this actor itself never
    /// touches `TranscriptState` beyond what it asks `writer` to persist.
    /// Cooperatively cancellable -- checks `Task.isCancelled` in every loop
    /// and lets `CancellationError` propagate out unmodified (§6.10) so the
    /// caller can distinguish "episode switch" from "real failure".
    ///
    /// `updates` is an `AsyncStream<ProgressUpdate>.Continuation` rather
    /// than a callback closure deliberately: `TranscriptHandle` is a
    /// `@MainActor` class and is not `Sendable`, so a closure capturing it
    /// could not itself be `@Sendable` -- which this parameter must be,
    /// since it's invoked from this actor's isolation domain after being
    /// handed in from `TranscriptProvider`'s. A `Continuation` over a
    /// `Sendable` element type has no such problem; `TranscriptProvider`
    /// consumes the stream concurrently (via `async let`) in its own
    /// context and is the only place that ever touches `TranscriptHandle`.
    func run(_ input: Input, writer: TranscriptWriter, updates: AsyncStream<ProgressUpdate>.Continuation) async throws {
        defer { updates.finish() }

        let transcriber = SpeechTranscriber(
            locale: input.requestedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        try Task.checkCancellation()
        try await ensureAssetsInstalled(for: transcriber, logger: logger)

        try Task.checkCancellation()
        let audioFile = try openAudioFile(at: input.audioFileURL)

        let resumeSeekSeconds = input.resume.map { max(0, $0.lastSegmentEndTime - 2.0) } ?? 0
        if resumeSeekSeconds > 0 {
            seekAudioFile(audioFile, toSeconds: resumeSeekSeconds, logger: logger)
        }

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        // VERIFY(iOS26): capturing `audioFile` (an `AVAudioFile`, a class)
        // into this Task's `@Sendable` closure assumes `AVAudioFile` is
        // safe to touch from a single background Task with no other
        // concurrent access -- true here (nothing else touches `audioFile`
        // once this task is created). Matches `spikes/FeasibilitySpike/
        // Sources/spike/TranscribeCommand.swift`'s identical pattern/note;
        // if Swift 6 strict concurrency rejects this on the real SDK, wrap
        // `audioFile` in a small actor here, isolated to this function.
        let feedTask = Task {
            defer { inputContinuation.finish() }
            // A few hundred ms per buffer.
            let frameCount: AVAudioFrameCount = 4096 * 16
            while true {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else { break }
                try audioFile.read(into: buffer, frameCount: frameCount)
                if buffer.frameLength == 0 { break } // EOF
                inputContinuation.yield(AnalyzerInput(buffer: buffer)) // VERIFY(iOS26): initializer shape.
            }
        }

        async let analyzeRun: Void = analyzer.start(inputSequence: inputSequence) // VERIFY(iOS26): method name; may throw.

        var batching = BatchingState(nextIndex: input.resume?.nextSegmentIndex ?? 0)
        var resolvedTimestampOffset: TimeInterval?

        do {
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else {
                    // Volatile: never persisted (§6.6) -- v1 ignores it
                    // entirely for the transcript store.
                    continue
                }

                var words = extractWords(from: result.text)
                guard !words.isEmpty else { continue }

                if resumeSeekSeconds > 0, resolvedTimestampOffset == nil {
                    resolvedTimestampOffset = resolveTimestampOffset(
                        firstRawWordStart: words[0].start,
                        seekOffsetSeconds: resumeSeekSeconds,
                        logger: logger
                    )
                }
                if let offset = resolvedTimestampOffset, offset > 0 {
                    words = words.map { RawTranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
                }

                try await handleFinalizedWords(words, resume: input.resume, batching: &batching, writer: writer, input: input, updates: updates)
            }
        } catch is CancellationError {
            feedTask.cancel()
            throw CancellationError()
        } catch {
            feedTask.cancel()
            _ = try? await analyzeRun
            throw TranscriptionEngineError.analyzerError(underlying: String(describing: error))
        }

        feedTask.cancel()
        do {
            try await analyzeRun
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionEngineError.analyzerError(underlying: String(describing: error))
        }

        try Task.checkCancellation()

        // End of stream: flush the normalizer's trailing partial sentence
        // (§4.6's finalizeStream) and force a final write regardless of the
        // 20-segment/10s-of-audio batching thresholds (§6.8), then mark
        // `.complete`. An empty-but-complete transcript (e.g. fully silent
        // audio) is valid.
        var tail = SegmentNormalizer.finalizeStream(state: &batching.streamState)
        if let resume = input.resume {
            tail = tail.filter { $0.endTime >= resume.lastSegmentEndTime }
        }
        batching.pendingSegments.append(contentsOf: tail)
        try await flush(&batching, writer: writer, transcriptID: input.transcriptID, newState: .complete, input: input, updates: updates)
    }

    // MARK: - Batching (§6.8)

    private struct BatchingState {
        var streamState: SegmentNormalizer.StreamState
        var pendingSegments: [NormalizedSegment] = []
        var lastWrittenEndTime: TimeInterval = 0

        init(nextIndex: Int) {
            streamState = SegmentNormalizer.StreamState(nextIndex: nextIndex)
        }
    }

    private func handleFinalizedWords(
        _ words: [RawTranscriptWord],
        resume: ResumeInfo?,
        batching: inout BatchingState,
        writer: TranscriptWriter,
        input: Input,
        updates: AsyncStream<ProgressUpdate>.Continuation
    ) async throws {
        var newlyClosed = SegmentNormalizer.normalizeIncremental(newWords: words, state: &batching.streamState)
        if let resume {
            // §11.15: "drop newly produced segments that end before
            // lastSegment.endTime" -- the ~2s pre-roll fed to re-establish
            // recognizer context can regenerate segments that overlap
            // already-persisted ones; discard those, keep only genuinely
            // new coverage.
            newlyClosed = newlyClosed.filter { $0.endTime >= resume.lastSegmentEndTime }
        }
        batching.pendingSegments.append(contentsOf: newlyClosed)

        let audioSecondsSinceLastWrite = (words.last?.end ?? batching.lastWrittenEndTime) - batching.lastWrittenEndTime
        let shouldFlush = batching.pendingSegments.count >= 20 || audioSecondsSinceLastWrite >= 10.0
        if shouldFlush, !batching.pendingSegments.isEmpty {
            try await flush(&batching, writer: writer, transcriptID: input.transcriptID, newState: .partial, input: input, updates: updates)
        }
    }

    private func flush(
        _ batching: inout BatchingState,
        writer: TranscriptWriter,
        transcriptID: PersistentIdentifier,
        newState: TranscriptState,
        input: Input,
        updates: AsyncStream<ProgressUpdate>.Continuation
    ) async throws {
        guard !batching.pendingSegments.isEmpty || newState == .complete else { return }

        let snapshots = try await writer.appendSegments(batching.pendingSegments, transcriptID: transcriptID, newState: newState)
        if let lastEnd = batching.pendingSegments.last?.endTime {
            batching.lastWrittenEndTime = lastEnd
        }
        batching.pendingSegments = []

        // On completion, progress is always 1.0 regardless of how close
        // the last recognized word landed to `episodeDurationHint`
        // (trailing silence/credits music shouldn't leave a "97% done"
        // transcript that reads as still-in-progress).
        let progress: Double
        if newState == .complete {
            progress = 1.0
        } else if let duration = input.episodeDurationHint, duration > 0 {
            progress = min(1.0, max(0.0, batching.lastWrittenEndTime / duration))
        } else {
            progress = 0
        }

        updates.yield(ProgressUpdate(newSegments: snapshots, state: newState, progress: progress))
    }
}
