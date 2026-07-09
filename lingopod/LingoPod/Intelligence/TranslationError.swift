// M5
// Typed failure taxonomy (architecture §8: typed states, not alerts).
// M4 renders these as inline banners in the transcript overlay; see
// docs/specs/M5-translation.md §8 for the case -> copy/action mapping this
// enum backs (M5 does not own copy/UI, only the stable cases M4 switches
// on).
import Foundation

enum TranslationError: Error, Sendable, Equatable {
    /// Defensive guard fired (M4 should have hidden the affordance
    /// already, per §4's same-language guard). No banner — log at debug.
    case sameLanguage
    /// `LanguageAvailability` reports `.unsupported` for this pair.
    case unsupportedLanguagePair
    /// `LanguageAvailability` reports `.supported` (not yet installed).
    case languagePackNeedsDownload
    /// `prepare(from:to:)` called while offline (NWPathMonitor check).
    case downloadRequiresNetwork
    /// Wraps any unexpected framework error (batch failure, missing
    /// response id, `prepareTranslation()` throwing, etc). `String` only,
    /// so this stays `Equatable`/`Sendable`.
    case sessionUnavailable(reason: String)
    /// The underlying `Task` was cancelled (e.g. overlay dismissed
    /// mid-lookup). Not currently thrown anywhere in this module (§3.4:
    /// queued requests are left in the queue on cancellation, not failed),
    /// but kept in the taxonomy per spec §8 for M4's switch to be
    /// exhaustive against future use.
    case cancelled
}
