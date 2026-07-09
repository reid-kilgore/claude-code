// M0
// SwiftData model support type (architecture §4 `Transcript.state`,
// §11.1). Same `Codable`-conformance storage note as `DownloadState`.
import Foundation

public enum TranscriptState: Codable, Equatable, Sendable {
    case pending
    case partial
    case complete
    /// `reason` is a stable machine code from M3's `TranscriptFailureCode`
    /// (e.g. `unsupportedLocale`, `assetDownloadFailed`,
    /// `needsEpisodeDownload`, `audioUnreadable` — architecture §11.4).
    case failed(reason: String)
}
