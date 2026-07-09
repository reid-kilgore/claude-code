// M0
// SwiftData model support type (architecture §4 `Episode.downloadState`,
// §11.1). SwiftData stores any `Codable` property (including enums with
// associated values, which is why this isn't a raw-value-only enum) via
// its own encoding, so no additional storage plumbing is required here —
// `Codable` conformance is the "SwiftData-compatible storage" contract.
import Foundation

public enum DownloadState: Codable, Equatable, Sendable {
    case none
    /// 0...1, coarse/persisted periodically (not updated on every byte).
    case inProgress(progress: Double)
    case downloaded
    /// `reason` is a stable machine code, not localized copy (architecture
    /// §11.4's `failed(reason:)` convention).
    case failed(reason: String)
}
