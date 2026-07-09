// `spike transcribe <audio-file> --locale <bcp47> [--start <seconds>]`
//
// Mirrors the API surface of TranscriptionEngine (docs/specs/M3-transcripts.md
// §6): locale resolution, AssetInventory install, building
// SpeechAnalyzer/SpeechTranscriber with `attributeOptions: [.audioTimeRange]`,
// feeding an AVAudioFile through an AsyncStream<AnalyzerInput>, and consuming
// `transcriber.results` distinguishing volatile vs. final. All Speech/
// AVFoundation calls for this subcommand live in this one file.
//
// KEY FEASIBILITY QUESTION this subcommand is built to answer (architecture
// §11.15 — the "transcription is resumable" reconciliation decision): when
// `--start` seeks the AVAudioFile before feeding it to the analyzer, are the
// `audioTimeRange` timestamps SpeechTranscriber reports back (a) relative to
// the start of the fed buffer stream (i.e. reset to ~0 regardless of where in
// the file we started reading), or (b) somehow file-absolute? Since the
// analyzer only ever sees raw PCM buffers via AnalyzerInput — never the
// AVAudioFile or its framePosition — there is no channel through which the
// analyzer could learn "this stream starts at file-time 47.3s." The strong
// prior is (a), stream-relative. This subcommand prints both interpretations
// side by side (see the JSON lines and the final stats block) so a human
// running it on real hardware can confirm against known audio content, and
// the README's PASS/FAIL rubric spells out what each outcome implies for
// TranscriptionEngine.
import Foundation
import Speech
import AVFoundation
import CoreMedia

enum TranscribeCommand {
    private struct FinalizedWord {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    static func run(arguments: [String]) async {
        let parsed = ParsedArguments(arguments)
        guard let audioPath = parsed.positionals.first else {
            FileHandle.standardError.write("Usage: spike transcribe <audio-file> --locale <bcp47> [--start <seconds>]\n".data(using: .utf8)!)
            exit(64)
        }
        let requestedLocaleID = parsed.requireFlag("locale")
        let startSeconds = Double(parsed.flag("start") ?? "0") ?? 0

        let audioURL = URL(fileURLWithPath: audioPath)

        // ---- 1. Locale resolution (mirrors LocaleResolver.resolve, M3 §5, §7.3 step 4) ----
        // VERIFY(iOS26): see LocalesCommand.swift for the supportedLocales uncertainty.
        let supported = await SpeechTranscriber.supportedLocales
        let requested = Locale(identifier: requestedLocaleID)
        let resolvedLocale = supported.first(where: { $0.identifier(.bcp47) == requested.identifier(.bcp47) })
            ?? supported.first(where: { $0.language.languageCode == requested.language.languageCode })
        guard let resolvedLocale else {
            FileHandle.standardError.write("Locale \(requestedLocaleID) not in SpeechTranscriber.supportedLocales. Run `spike locales` first.\n".data(using: .utf8)!)
            exit(1)
        }
        stderrPrint("Resolved locale: \(resolvedLocale.identifier(.bcp47)) (requested \(requestedLocaleID))")

        // ---- 2. Build the transcriber/analyzer (M3 §6.4) ----
        // VERIFY(iOS26): transcriptionOptions/reportingOptions/attributeOptions
        // enum case names below are written to the documented shape from M3
        // §6.4; confirm against SDK headers on device.
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // ---- 3. Ensure locale assets installed (M3 §6.3) ----
        do {
            try await ensureAssetsInstalled(for: transcriber)
        } catch {
            FileHandle.standardError.write("Asset install failed: \(error)\n".data(using: .utf8)!)
            exit(1)
        }

        // ---- 4. Open audio file, optionally seek ----
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: audioURL)
        } catch {
            FileHandle.standardError.write("Could not open audio file at \(audioURL.path): \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalFrames = audioFile.length
        let audioDuration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0

        if startSeconds > 0 {
            let startFrame = AVAudioFramePosition((startSeconds * sampleRate).rounded())
            audioFile.framePosition = min(max(startFrame, 0), totalFrames)
            stderrPrint("Seeked to \(startSeconds)s -> frame \(audioFile.framePosition) of \(totalFrames) (audio duration \(audioDuration)s)")
        }

        // ---- 5. Feed audio through an AsyncStream (M3 §6.5) ----
        // VERIFY(iOS26): AnalyzerInput's exact initializer and the analyzer's
        // start/feed method names. Written to the most-documented public
        // shape per M3 §6.5.
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // VERIFY(iOS26): capturing `audioFile` (an AVAudioFile, a class) into
        // this Task's closure assumes AVAudioFile is safe to touch from a
        // single background Task with no other concurrent access — M3 §6.5's
        // own reference code does the same without extra ceremony. If Swift 6
        // strict concurrency rejects this (AVAudioFile not Sendable), the fix
        // is a small actor wrapper around the file handle; keep that fix
        // isolated here, don't restructure the rest of the pipeline.
        let feedTask = Task {
            defer { inputContinuation.finish() }
            let frameCount: AVAudioFrameCount = 4096 * 16 // a few hundred ms per buffer
            while true {
                try Task.checkCancellation()
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else { break }
                try audioFile.read(into: buffer, frameCount: frameCount)
                if buffer.frameLength == 0 { break } // EOF
                inputContinuation.yield(AnalyzerInput(buffer: buffer)) // VERIFY(iOS26): initializer shape
            }
        }

        let wallClockStart = Date()
        async let analyzeRun: Void = analyzer.start(inputSequence: inputSequence) // VERIFY(iOS26): method name; may throw

        var finalizedSegmentCount = 0
        var finalizedWordCount = 0
        var firstFinalizedAt: Date?
        var timestampSemantics: String = "no finalized results observed"
        var firstResultStreamRelativeStart: TimeInterval?

        do {
            // VERIFY(iOS26): transcriber.results element type/shape. Written
            // to the documented shape from M3 §6.6: an AsyncSequence whose
            // elements carry `.text: AttributedString` and `.isFinal: Bool`
            // (may instead be a `resultType` enum — confirm on device).
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else {
                    let volatileText = String(result.text.characters)
                    stderrPrint("[volatile] \(volatileText)")
                    continue
                }

                if firstFinalizedAt == nil {
                    firstFinalizedAt = Date()
                }

                let words = extractWords(from: result.text)
                guard let first = words.first, let last = words.last else { continue }

                finalizedSegmentCount += 1
                finalizedWordCount += words.count

                if firstResultStreamRelativeStart == nil {
                    firstResultStreamRelativeStart = first.start
                    timestampSemantics = classifyTimestampSemantics(
                        firstFinalizedStart: first.start,
                        requestedStartSeconds: startSeconds
                    )
                    stderrPrint("TIMESTAMP SEMANTICS CHECK: first finalized start=\(first.start)s, requested seek=\(startSeconds)s -> \(timestampSemantics)")
                }

                // §2 of M3-transcripts.md: RawTranscriptWord.text already
                // carries its natural spacing — concatenate with NO
                // separator to reproduce the framework's own text exactly.
                let text = words.map(\.text).joined()

                // {start, end, text} exactly, as the task brief specifies —
                // these are the RAW values SpeechTranscriber returned
                // (stream-relative per the analysis above, NOT
                // offset-adjusted). Compare against the printed seek offset
                // yourself; see README for how to read this.
                let payload: [String: Any] = [
                    "start": first.start,
                    "end": last.end,
                    "text": text
                ]
                printJSONLine(payload)
            }
        } catch is CancellationError {
            stderrPrint("Results loop cancelled.")
        } catch {
            FileHandle.standardError.write("Results loop error: \(error)\n".data(using: .utf8)!)
        }

        feedTask.cancel()
        do {
            try await analyzeRun
        } catch {
            stderrPrint("analyzer.start(inputSequence:) threw: \(error)")
        }

        let wallClockSeconds = Date().timeIntervalSince(wallClockStart)
        let realTimeFactor = audioDuration > 0 ? wallClockSeconds / audioDuration : Double.nan
        let timeToFirstFinalized = firstFinalizedAt.map { $0.timeIntervalSince(wallClockStart) } ?? -1

        stderrPrint("")
        stderrPrint("=== STATS ===")
        let stats: [String: Any] = [
            "audioDurationSeconds": audioDuration,
            "wallClockSeconds": wallClockSeconds,
            "realTimeFactor": realTimeFactor,
            "finalizedSegmentCount": finalizedSegmentCount,
            "finalizedWordCount": finalizedWordCount,
            "timeToFirstFinalizedSeconds": timeToFirstFinalized,
            "startOffsetRequestedSeconds": startSeconds,
            "timestampSemantics": timestampSemantics
        ]
        if let data = try? JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            print(string)
        }

        print("")
        print("realTimeFactor < 1.0 means transcription ran faster than playback (validates architecture §6 decision 1's 'ahead of the playhead' design).")
    }

    /// M3 §6.3.
    private static func ensureAssetsInstalled(for transcriber: SpeechTranscriber) async throws {
        // VERIFY(iOS26): "already installed" check name/shape — M3 §6.3
        // names two candidates; this spike uses `installedLocales.contains`.
        let installed = await AssetInventory.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == transcriber.locale.identifier(.bcp47) }) {
            stderrPrint("Locale assets already installed — skipping download.")
            return
        }

        stderrPrint("Installing locale assets for \(transcriber.locale.identifier(.bcp47))...")
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])

        // VERIFY(iOS26): request.progress is a Foundation `Progress`;
        // observe fractionCompleted via KVO or polling (Progress isn't
        // directly Sendable/awaitable). Simple cancellation-safe polling
        // loop per M3 §6.3's own suggestion.
        let progressTask = Task {
            while !Task.isCancelled {
                stderrPrint("  asset install progress: \(Int(request.progress.fractionCompleted * 100))%")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { progressTask.cancel() }

        try await request.downloadAndInstall() // VERIFY(iOS26): exact method name
        stderrPrint("Asset install complete.")
    }

    /// M3 §6.6-6.7.
    private static func extractWords(from text: AttributedString) -> [FinalizedWord] {
        var result: [FinalizedWord] = []
        for run in text.runs {
            // VERIFY(iOS26): exact attribute key for reading a run's
            // audioTimeRange (e.g. `run.audioTimeRange`, or
            // `run[SomeAttributeScope.audioTimeRange]`) — M3 §6.6.
            guard let timeRange = run.audioTimeRange else { continue }
            let substring = String(text[run.range].characters)
            let start = TimeInterval(CMTimeGetSeconds(timeRange.start))
            let end = TimeInterval(CMTimeGetSeconds(timeRange.start + timeRange.duration))
            // M3 §6.7: CMTimeGetSeconds can return .nan/.infinity for
            // invalid/indefinite times — guard before propagating.
            guard start.isFinite, end.isFinite else { continue }
            result.append(FinalizedWord(text: substring, start: start, end: end))
        }
        return result
    }

    /// Heuristic classifier for the §11.15 key finding described in this
    /// file's header comment. `firstFinalizedStart` is the raw value
    /// SpeechTranscriber reported for the very first finalized word after a
    /// `--start` seek; if it's ~0 the analyzer has no idea we seeked
    /// (stream-relative timestamps); if it's ~requestedStartSeconds, the
    /// framework is somehow threading file-position context through
    /// (file-absolute timestamps) — which would be surprising given
    /// AnalyzerInput only carries raw PCM buffers, but this spike exists
    /// precisely to not assume the answer.
    private static func classifyTimestampSemantics(firstFinalizedStart: TimeInterval, requestedStartSeconds: TimeInterval) -> String {
        guard requestedStartSeconds > 0 else {
            return "n/a (no --start offset requested)"
        }
        let toleranceSeconds = 3.0 // generous: first finalized chunk may cover several seconds of speech
        if abs(firstFinalizedStart) <= toleranceSeconds {
            return "STREAM-RELATIVE (starts near 0 despite --start=\(requestedStartSeconds)s seek)"
        }
        if abs(firstFinalizedStart - requestedStartSeconds) <= toleranceSeconds {
            return "FILE-ABSOLUTE (starts near the requested --start=\(requestedStartSeconds)s offset)"
        }
        return "INCONCLUSIVE (start=\(firstFinalizedStart)s matches neither 0 nor \(requestedStartSeconds)s within \(toleranceSeconds)s tolerance — inspect manually)"
    }

    private static func printJSONLine(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    }

    private static func stderrPrint(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
