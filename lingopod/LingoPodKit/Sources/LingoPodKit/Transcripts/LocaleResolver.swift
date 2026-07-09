// M3
// Pure locale normalization/matching (docs/specs/M3-transcripts.md §5). No
// Speech import — the caller (app target) fetches `SpeechTranscriber.
// supportedLocales`; this type only does the matching logic, so it's
// unit-testable without the Speech framework.
import Foundation

public enum LocaleResolver {
    /// Normalizes a raw feed/user string into a `Locale.Language`, or `nil`
    /// if it's empty/unparseable. Handles `"en-us"` (case), `"en_US"`
    /// (underscore), `"ES"` (bare, uppercase), `"es-419"` (UN numeric
    /// macro-region), `"pt-BR"`.
    public static func normalizeBCP47(_ raw: String?) -> Locale.Language? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")

        // Light regex gate before trusting `Locale.Language(identifier:)`,
        // which doesn't reliably reject garbage (`Locale.Language` /
        // Foundation — VERIFY(iOS26): don't rely on its failability).
        let pattern = "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"
        guard normalized.range(of: pattern, options: .regularExpression) != nil else {
            return nil
        }

        return Locale.Language(identifier: normalized)
    }

    /// `supported` is whatever `SpeechTranscriber.supportedLocales`
    /// returned (app-target glue fetches that list; this function does the
    /// matching). Returns the *actual* supported `Locale` to use, or `nil`
    /// if none match.
    public static func resolve(requested: Locale.Language, supported: [Locale]) -> Locale? {
        guard let requestedLanguageCode = requested.languageCode else { return nil }

        // Exact match first: languageCode, and (if requested has a region)
        // region too.
        if let requestedRegion = requested.region {
            if let exact = supported.first(where: {
                $0.language.languageCode == requestedLanguageCode && $0.language.region == requestedRegion
            }) {
                return exact
            }
        } else if let exact = supported.first(where: { $0.language.languageCode == requestedLanguageCode }) {
            return exact
        }

        // Language-code-only fallback: region ignored. Non-deterministic
        // across OS/locale-list versions if multiple regions are supported
        // for one language — accepted (§5); whichever is chosen is written
        // into `Transcript.languageCode` as the actual locale used.
        return supported.first(where: { $0.language.languageCode == requestedLanguageCode })
    }
}
