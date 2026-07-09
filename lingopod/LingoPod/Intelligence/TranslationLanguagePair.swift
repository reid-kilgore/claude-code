// M5
// Small value type used throughout TranslationService's queue/coalescing
// logic (docs/specs/M5-translation.md §3.3) to key per-pair timers/waiters.
import Foundation

/// A resolved (source, target) language pair. `Hashable` so it can key
/// per-pair queue/waiter dictionaries.
struct LanguagePair: Hashable, Sendable {
    let source: Locale.Language
    let target: Locale.Language
}
