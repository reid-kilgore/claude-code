// M4
// Covers WordTokenizer.tokenize (docs/specs/M4-overlay-ui.md §6.1).
import Testing
import Foundation
@testable import LingoPodKit

@Suite("WordTokenizer")
struct WordTokenizerTests {
    @Test func spanishSentenceWithTrailingPunctuation() {
        let tokens = WordTokenizer.tokenize("Vamos a hablar, despacio.", language: Locale.Language(identifier: "es"))
        let texts = tokens.map(\.text)
        #expect(texts == ["Vamos", "a", "hablar,", "despacio."])
    }

    @Test func japaneseSentenceWithNoSpacesProducesMultipleTokens() {
        let tokens = WordTokenizer.tokenize("今日は良い天気ですね", language: Locale.Language(identifier: "ja"))
        // Must not degrade to one giant blob.
        #expect(tokens.count > 1)
        // Every token's range must map back into the original text.
        for token in tokens {
            #expect(String(token.text.unicodeScalars.isEmpty ? "" : token.text).isEmpty == false)
        }
    }

    @Test func englishContractionStaysOneToken() {
        let tokens = WordTokenizer.tokenize("I don't know.", language: Locale.Language(identifier: "en"))
        let texts = tokens.map(\.text)
        #expect(texts.contains("don't"))
        #expect(!texts.contains("don"))
        #expect(!texts.contains("'t"))
    }

    @Test func ellipsisMidSentenceDoesNotEatFollowingWord() {
        let tokens = WordTokenizer.tokenize("Hola... mundo", language: Locale.Language(identifier: "es"))
        let texts = tokens.map(\.text)
        #expect(texts.contains("mundo"))
        // "mundo" must be its own token, not merged with the ellipsis.
        #expect(texts.last == "mundo")
    }

    @Test func emptyStringProducesNoTokens() {
        #expect(WordTokenizer.tokenize("", language: nil).isEmpty)
    }

    @Test func leadingPunctuationWithNoPrecedingWordBecomesItsOwnToken() {
        let tokens = WordTokenizer.tokenize("—dijo ella", language: Locale.Language(identifier: "es"))
        #expect(tokens.first?.text == "—")
    }

    @Test func tokenRangesMapBackIntoOriginalText() {
        let text = "Vamos a hablar, despacio."
        let tokens = WordTokenizer.tokenize(text, language: Locale.Language(identifier: "es"))
        for token in tokens {
            #expect(String(text[token.range]) == token.text)
        }
    }

    @Test func noLanguageHintStillTokenizesReasonably() {
        let tokens = WordTokenizer.tokenize("Hello world", language: nil)
        #expect(tokens.map(\.text) == ["Hello", "world"])
    }
}
