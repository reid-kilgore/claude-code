// M4
// Pure, framework-light word/phrase tokenization for the transcript
// overlay's tap targets (docs/specs/M4-overlay-ui.md §6.1). Uses
// `NLTokenizer`'s word unit, which correctly segments no-space scripts
// (CJK, Thai, ...) when given a language hint, and falls back to automatic
// detection otherwise. No UIKit/SwiftUI import, so this is unit-testable
// with plain `swift test` alongside the rest of LingoPodKit.
import Foundation
import NaturalLanguage

/// One tappable/selectable unit of transcript text. Trailing punctuation is
/// merged into the preceding word (see `WordTokenizer.tokenize`'s doc), so
/// `"hablar,"` is a single token rather than `"hablar"` + `","`.
public struct WordToken: Equatable, Sendable {
    /// Display text, including any merged trailing punctuation.
    public let text: String
    /// Range into the *original* segment text this token was cut from.
    public let range: Range<String.Index>

    public init(text: String, range: Range<String.Index>) {
        self.text = text
        self.range = range
    }
}

public enum WordTokenizer {
    /// Splits `text` into tappable word-ish tokens.
    ///
    /// - `language`, when provided, is used as an `NLTokenizer` language
    ///   hint (converted from `Locale.Language` via its `languageCode`
    ///   identifier); when `nil`, `NLTokenizer`'s automatic detection is
    ///   used instead.
    /// - Whitespace-only tokens are dropped entirely — the caller's flow
    ///   layout supplies its own inter-token spacing.
    /// - A token that is entirely punctuation/symbol characters is merged
    ///   into the immediately preceding word token (no gap between their
    ///   ranges), extending that token's text/range, so trailing
    ///   punctuation stays attached to its word. A punctuation run that is
    ///   *not* immediately adjacent to a preceding token (e.g. separated by
    ///   whitespace) — or that appears before any word token has been
    ///   emitted yet (e.g. text starting with "—") — becomes its own token
    ///   rather than being merged or dropped.
    ///
    /// Call once per segment when the segment first appears; never call
    /// this from a per-frame/per-tick hot path (docs/specs/M4-overlay-ui.md
    /// §6.1, §11).
    public static func tokenize(_ text: String, language: Locale.Language?) -> [WordToken] {
        guard !text.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        // VERIFY(iOS26): `NLLanguage` is documented as an `NLLanguage(String)`
        // wrapper around a BCP-47-ish language code; confirm this still
        // accepts a bare `languageCode.identifier` (e.g. "es", "ja") as of
        // the shipping SDK.
        if let identifier = language?.languageCode?.identifier {
            tokenizer.setLanguage(NLLanguage(identifier))
        }
        tokenizer.string = text

        var tokens: [WordToken] = []
        let punctuationAndSymbols = CharacterSet.punctuationCharacters.union(.symbols)

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let substring = text[range]

            if substring.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                return true
            }

            let isPunctuationRun = substring.unicodeScalars.allSatisfy { punctuationAndSymbols.contains($0) }

            if isPunctuationRun, let last = tokens.last, last.range.upperBound == range.lowerBound {
                let mergedRange = last.range.lowerBound..<range.upperBound
                let mergedText = String(text[mergedRange])
                tokens[tokens.count - 1] = WordToken(text: mergedText, range: mergedRange)
            } else {
                tokens.append(WordToken(text: String(substring), range: range))
            }
            return true
        }

        return tokens
    }
}
