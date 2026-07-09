// M3
// The `Speech`/`AVFoundation` framework-touching seam for `TranscriptionEngine`
// (docs/specs/M3-transcripts.md §6.3, §6.6, §6.7; architecture §9's
// "framework-touching seams... wrapped in thin protocols and left for
// on-device verification"). Every `VERIFY(iOS26)` call in this file mirrors
// the confirmed shape in `spikes/FeasibilitySpike/Sources/spike/
// TranscribeCommand.swift` / `LocalesCommand.swift` -- those spikes are the
// same API surface exercised on real hardware; if the SDK's actual shape
// differs, fix the call sites in *this file only*, per architecture §10.
import Foundation
import AVFoundation
import CoreMedia
import Speech
import LingoPodKit
import os

extension TranscriptionEngine {

    // MARK: - Locale queries (§7.3 step 4, §6.3)

    /// VERIFY(iOS26): confirmed shape per `spikes/.../LocalesCommand.swift`
    /// -- `static var supportedLocales: [Locale] { get async }`.
    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    // MARK: - Asset installation (§6.3)

    /// VERIFY(iOS26): "already installed" check uses
    /// `AssetInventory.installedLocales.contains(...)` per the spike (M3
    /// §6.3 names this as one of two candidate shapes; the spike settled on
    /// this one). Skips the download entirely if already installed so
    /// re-opening an already-transcribed-in-this-language episode doesn't
    /// re-download.
    func ensureAssetsInstalled(for transcriber: SpeechTranscriber, logger: Logger) async throws {
        let installed = await AssetInventory.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == transcriber.locale.identifier(.bcp47) }) {
            logger.debug("Locale assets already installed; skipping download.")
            return
        }

        logger.info("Installing locale assets for \(transcriber.locale.identifier(.bcp47), privacy: .public)...")
        do {
            // VERIFY(iOS26): exact static method name/shape and the
            // request's concrete type -- left to inference (as the spec's
            // own §6.3 sample does) rather than guessing a type name here.
            let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])

            // VERIFY(iOS26): `request.progress` is a Foundation `Progress`,
            // not directly Sendable/awaitable -- polling loop per M3 §6.3's
            // own suggestion, cancellation-safe.
            let progressTask = Task {
                while !Task.isCancelled {
                    logger.debug("Asset install progress: \(Int(request.progress.fractionCompleted * 100))%")
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { progressTask.cancel() }

            try await request.downloadAndInstall() // VERIFY(iOS26): exact method name.
        } catch {
            if Self.isConnectivityError(error) {
                throw TranscriptionEngineError.assetDownloadNoNetwork(underlying: String(describing: error))
            }
            throw TranscriptionEngineError.assetDownloadFailed(underlying: String(describing: error))
        }
        logger.info("Asset install complete.")
    }

    /// VERIFY(iOS26): `AssetInventory`'s network-failure error domain is
    /// unconfirmed -- it may not surface a plain `URLError` at all. Falls
    /// back to the generic `.assetDownloadFailed` code when it doesn't
    /// look like `URLError.notConnectedToInternet`/`.networkConnectionLost`
    /// (M3 spec §6.3).
    private static func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    // MARK: - Audio file (§6.5, §11.15 resume seek)

    func openAudioFile(at url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionEngineError.audioFileUnreadable(underlying: String(describing: error))
        }
    }

    /// §11.15 resume support. VERIFY(iOS26): `SpeechAnalyzer`/
    /// `analyzeSequence`/`AnalyzerInput` document no mid-file start
    /// parameter, so this seeks the file's read position directly via
    /// `framePosition` *before* any buffers are fed -- confirmed workable
    /// in `spikes/.../TranscribeCommand.swift`'s `--start` flag. Whether
    /// the resulting `audioTimeRange` timestamps come back stream-relative
    /// or file-absolute is exactly what that spike measures; see
    /// `resolveTimestampOffset` below for the defensive runtime branch.
    func seekAudioFile(_ audioFile: AVAudioFile, toSeconds seconds: TimeInterval, logger: Logger) {
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0, seconds > 0 else { return }
        let targetFrame = AVAudioFramePosition((seconds * sampleRate).rounded())
        let clamped = min(max(targetFrame, 0), audioFile.length)
        audioFile.framePosition = clamped
        logger.info("§11.15 resume: seeked audio file to \(seconds, privacy: .public)s (frame \(clamped, privacy: .public) of \(audioFile.length, privacy: .public)).")
    }

    /// §11.15 defensive branch (this integration's brief, "fresh
    /// feasibility findings"): decided once, from the very first finalized
    /// word observed after a resume seek. If that word's raw reported start
    /// time is small (looks like the analyzer reset to ~0 regardless of the
    /// file-position seek -- the strong prior per the spike's header
    /// comment, since `AnalyzerInput` only ever carries raw PCM buffers with
    /// no channel to communicate file position), treat all timestamps in
    /// this run as stream-relative and add `seekOffsetSeconds` to each one.
    /// Otherwise trust them as already file-absolute and apply no
    /// adjustment. Logs which branch ran so a real device run can confirm.
    func resolveTimestampOffset(firstRawWordStart: TimeInterval, seekOffsetSeconds: TimeInterval, logger: Logger) -> TimeInterval {
        guard seekOffsetSeconds > 0 else { return 0 }
        let epsilonSeconds = 3.0
        if firstRawWordStart < epsilonSeconds {
            logger.info("§11.15 resume: timestamps look STREAM-RELATIVE (first finalized word start=\(firstRawWordStart, privacy: .public)s after seeking \(seekOffsetSeconds, privacy: .public)s) -- applying +\(seekOffsetSeconds, privacy: .public)s to all subsequent timestamps this run.")
            return seekOffsetSeconds
        }
        logger.info("§11.15 resume: timestamps look FILE-ABSOLUTE already (first finalized word start=\(firstRawWordStart, privacy: .public)s ~= seek offset \(seekOffsetSeconds, privacy: .public)s) -- no adjustment applied.")
        return 0
    }

    // MARK: - Result extraction (§6.6, §6.7)

    /// VERIFY(iOS26): the exact attribute key for reading a run's
    /// `audioTimeRange` (e.g. `run.audioTimeRange`). A run's granularity is
    /// "approximately one word" per the task brief, but this loop makes no
    /// assumption about exact word-per-run granularity -- it just walks
    /// whatever runs exist.
    func extractWords(from text: AttributedString) -> [RawTranscriptWord] {
        var result: [RawTranscriptWord] = []
        for run in text.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let substring = String(text[run.range].characters)
            let start = TimeInterval(CMTimeGetSeconds(timeRange.start))
            let end = TimeInterval(CMTimeGetSeconds(timeRange.start + timeRange.duration))
            // §6.7: CMTimeGetSeconds can return .nan/.infinity for
            // invalid/indefinite times -- guard before propagating.
            guard start.isFinite, end.isFinite else { continue }
            result.append(RawTranscriptWord(text: substring, start: start, end: end))
        }
        return result
    }
}
