// M0
// SwiftData model support type (architecture §4 `Transcript.source`,
// §11.1).
import Foundation

public enum TranscriptSource: String, Codable, Equatable, Sendable {
    case feed
    case onDevice
}
