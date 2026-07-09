// M3
// Stable, non-localized failure codes. `TranscriptState.failed(reason:)`
// stores `code.rawValue` (architecture §11.4). M4 owns mapping codes to
// localized, user-facing copy and an action button; M3 never produces
// localized prose here. docs/specs/M3-transcripts.md §2, §9.
import Foundation

public enum TranscriptFailureCode: String, Sendable, Equatable {
    /// Podcast has no languageCode/languageOverride, or it's unparseable.
    case noLanguageSpecified
    /// Resolved locale not in `SpeechTranscriber.supportedLocales`.
    case unsupportedLocale
    /// `AssetInventory` install request threw (non-connectivity reason).
    case assetDownloadFailed
    /// Same call, recognizably a connectivity failure.
    case assetDownloadNoNetwork
    /// `AVAudioFile` init threw, or `localAudioPath` missing on disk.
    case audioFileUnreadable
    /// `SpeechAnalyzer`/`SpeechTranscriber` threw mid-stream (not cancellation).
    case analyzerError
    /// On-device path chosen but episode never finished downloading
    /// (watcher timeout / download failed).
    case needsDownload
    /// `URLSession` error/non-2xx fetching `feedTranscriptURL`.
    case feedFetchFailed
    /// MIME/extension/content sniff didn't match a known parser.
    case feedUnsupportedFormat
    /// Parser threw on the fetched bytes.
    case feedParseError
}
