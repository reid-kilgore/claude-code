// M5
// Wraps every real `TranslationSession` call behind a protocol so the
// coalescing/queue logic in TranslationService is unit-testable without
// booting the Translation framework (architecture §9: "framework-touching
// seams ... are wrapped in thin protocols"). No other file in this module
// references `TranslationSession` directly.
import Foundation
import Translation

protocol TranslationSessionProtocol: Sendable {
    /// Returns translated text keyed by request id (`.uuidString`). Any id
    /// missing from the result is treated as a per-item failure by the
    /// caller (TranslationService.flush).
    func performBatch(_ requests: [PendingTranslationRequest]) async throws -> [String: String]

    /// Triggers the system's pack-download prompt/sheet for this session's
    /// configured source/target pair (or no-ops if already installed).
    func prepareTranslation() async throws
}

struct LiveTranslationSession: TranslationSessionProtocol {
    let session: TranslationSession

    func performBatch(_ requests: [PendingTranslationRequest]) async throws -> [String: String] {
        // VERIFY(iOS26): confirm exact batch API name/shape. Documented
        // shape as of this writing: TranslationSession.Request(sourceText:
        // clientIdentifier:) and `session.translations(from:
        // [TranslationSession.Request]) async throws ->
        // [TranslationSession.Response]`, where Response exposes
        // `.targetText` and `.clientIdentifier`. If the real signature
        // differs, this is the only function that needs to change.
        let requestObjects = requests.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
        }
        let responses = try await session.translations(from: requestObjects)
        var out: [String: String] = [:]
        for response in responses {
            if let clientIdentifier = response.clientIdentifier {
                out[clientIdentifier] = response.targetText
            }
        }
        return out
    }

    func prepareTranslation() async throws {
        // VERIFY(iOS26): confirm TranslationSession exposes
        // prepareTranslation(); documented shape: `try await
        // session.prepareTranslation()` triggers the system's
        // pack-download prompt/sheet for the session's configured pair.
        try await session.prepareTranslation()
    }
}
