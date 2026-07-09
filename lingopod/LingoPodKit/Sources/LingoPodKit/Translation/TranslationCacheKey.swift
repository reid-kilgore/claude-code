// M5
// Pure logic (no SwiftData/UIKit/SwiftUI), platform-agnostic per
// architecture §1, mirroring the Feeds/ and Transcripts/ pattern for
// `swift test`-runnable code. See docs/specs/M5-translation.md §6.2.
import Foundation

public enum TranslationCacheKey {
    /// NFC-normalize, lowercase, collapse internal whitespace runs to a
    /// single space, then trim leading/trailing whitespace and punctuation.
    /// Trimming only affects the ends of the string — "geht's" keeps its
    /// internal apostrophe; "¿Cómo estás?" becomes "cómo estás".
    public static func normalize(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping
        let lowered = nfc.lowercased()
        let collapsed = lowered.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return collapsed.trimmingCharacters(in: trimSet)
    }

    /// Matches the `TranslationCacheEntry.key` format in architecture §4
    /// exactly: "\(sourceLang)|\(targetLang)|\(normalizedText)". `source`/
    /// `target` are caller-supplied identifiers (use
    /// `Locale.Language.minimalIdentifier` at the call site — kept as plain
    /// Strings here so this file stays Foundation-only and
    /// platform-agnostic per architecture §1).
    public static func make(text: String, source: String, target: String) -> String {
        "\(source)|\(target)|\(normalize(text))"
    }
}
