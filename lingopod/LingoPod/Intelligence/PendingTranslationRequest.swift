// M5
// docs/specs/M5-translation.md §3.3.
import Foundation

/// One queued word/phrase translation request awaiting a batch flush.
struct PendingTranslationRequest: Sendable {
    let id: UUID
    let text: String
    let pair: LanguagePair
}
