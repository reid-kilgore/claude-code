// M6
// Real, `swift test`-runnable unit tests for the pure logic in
// Sources/LingoPodKit/Explain/ExplainPrompting.swift (docs/specs/M6-explain.md
// §8.1). Mirrors M5's `TranslationTests.swift` in style/location.
import Foundation
import Testing
@testable import LingoPodKit

private let es = Locale.Language(identifier: "es")
private let en = Locale.Language(identifier: "en")
private let fr = Locale.Language(identifier: "fr")

// MARK: - makeInstructions / makeTranslationFallbackInstructions

@Test func makeInstructionsSubstitutesBothPlaceholders() {
    let text = ExplainPrompting.makeInstructions(sourceLanguage: es, targetLanguage: en)
    #expect(!text.contains("{SOURCE_LANGUAGE_NAME}"))
    #expect(!text.contains("{TARGET_LANGUAGE_NAME}"))
    #expect(text.contains("Spanish"))
    #expect(text.contains("English"))
}

@Test func makeTranslationFallbackInstructionsSubstitutesBothPlaceholders() {
    let text = ExplainPrompting.makeTranslationFallbackInstructions(sourceLanguage: fr, targetLanguage: en)
    #expect(!text.contains("{SOURCE_LANGUAGE_NAME}"))
    #expect(!text.contains("{TARGET_LANGUAGE_NAME}"))
    #expect(text.contains("French"))
    #expect(text.contains("English"))
}

// MARK: - makePrompt

@Test func makePromptContainsDelimitersInOrderAndFramingSentence() {
    let prompt = ExplainPrompting.makePrompt(
        passage: "no lo puedo creer",
        context: "no lo puedo creer, en serio",
        sourceLanguage: es,
        targetLanguage: en
    )
    let contextOpen = prompt.range(of: "<context>")
    let contextClose = prompt.range(of: "</context>")
    let passageOpen = prompt.range(of: "<passage>")
    let passageClose = prompt.range(of: "</passage>")
    #expect(contextOpen != nil && contextClose != nil && passageOpen != nil && passageClose != nil)
    if let a = contextOpen, let b = contextClose, let c = passageOpen, let d = passageClose {
        #expect(a.lowerBound < b.lowerBound)
        #expect(b.upperBound < c.lowerBound)
        #expect(c.lowerBound < d.lowerBound)
    }
    #expect(prompt.contains("no lo puedo creer"))
    #expect(prompt.contains("The passage above is in Spanish. Explain it in English, following your instructions."))
}

// MARK: - trimContext

@Test func trimContextUnderLimitPassesThrough() {
    let context = "short context around a passage"
    let result = ExplainPrompting.trimContext(context, aroundPassage: "passage", limit: 600)
    #expect(result == context)
}

@Test func trimContextSymmetricTrimAroundCenteredPassage() {
    let passage = "PASSAGE"
    let padding = String(repeating: "x", count: 1000)
    let context = padding + passage + padding
    let result = ExplainPrompting.trimContext(context, aroundPassage: passage, limit: 600)
    #expect(result.utf16.count <= 600)
    #expect(result.contains(passage))
    // Roughly symmetric: similar amounts of padding on each side.
    guard let range = result.range(of: passage) else {
        Issue.record("passage missing from trimmed result")
        return
    }
    let leftCount = result.distance(from: result.startIndex, to: range.lowerBound)
    let rightCount = result.distance(from: range.upperBound, to: result.endIndex)
    #expect(abs(leftCount - rightCount) <= 1)
}

@Test func trimContextAsymmetricBudgetWhenPassageNearEdge() {
    let passage = "PASSAGE"
    // Passage sits only 10 chars from the start, with a huge amount of
    // trailing text -- the left side should run out of budget quickly and
    // hand the remainder to the right side, while still respecting the
    // overall limit.
    let context = String(repeating: "a", count: 10) + passage + String(repeating: "b", count: 2000)
    let result = ExplainPrompting.trimContext(context, aroundPassage: passage, limit: 600)
    #expect(result.utf16.count <= 600)
    #expect(result.contains(passage))
    #expect(result.hasPrefix(String(repeating: "a", count: 10)))
    guard let range = result.range(of: passage) else {
        Issue.record("passage missing from trimmed result")
        return
    }
    let rightCount = result.distance(from: range.upperBound, to: result.endIndex)
    // Left had only 10 chars available, so almost the entire remaining
    // budget (600 - passage.count - 10) should have gone to the right.
    #expect(rightCount > 500)
}

@Test func trimContextPassageNotFoundFallsBackToPrefix() {
    let context = String(repeating: "z", count: 1000)
    let result = ExplainPrompting.trimContext(context, aroundPassage: "not present anywhere", limit: 600)
    #expect(result.utf16.count == 600)
    #expect(result == String(repeating: "z", count: 600))
}

// MARK: - cacheKey

@Test func cacheKeyIsDeterministic() {
    let a = ExplainPrompting.cacheKey(passage: "hola", context: "hola que tal", sourceLanguage: es, targetLanguage: en)
    let b = ExplainPrompting.cacheKey(passage: "hola", context: "hola que tal", sourceLanguage: es, targetLanguage: en)
    #expect(a == b)
}

@Test func cacheKeyIsWhitespaceInsensitive() {
    let a = ExplainPrompting.cacheKey(passage: "hola  mundo", context: "  hola   mundo  ", sourceLanguage: es, targetLanguage: en)
    let b = ExplainPrompting.cacheKey(passage: "hola mundo", context: "hola\nmundo", sourceLanguage: es, targetLanguage: en)
    #expect(a == b)
}

@Test func cacheKeyDiffersByTargetLanguage() {
    let a = ExplainPrompting.cacheKey(passage: "hola", context: "hola que tal", sourceLanguage: es, targetLanguage: en)
    let b = ExplainPrompting.cacheKey(passage: "hola", context: "hola que tal", sourceLanguage: es, targetLanguage: fr)
    #expect(a != b)
}

@Test func cacheKeyDiffersByPassage() {
    let a = ExplainPrompting.cacheKey(passage: "hola", context: "hola que tal", sourceLanguage: es, targetLanguage: en)
    let b = ExplainPrompting.cacheKey(passage: "adios", context: "hola que tal", sourceLanguage: es, targetLanguage: en)
    #expect(a != b)
}

@Test func cacheKeyDiffersByContext() {
    let a = ExplainPrompting.cacheKey(passage: "hola", context: "hola que tal", sourceLanguage: es, targetLanguage: en)
    let b = ExplainPrompting.cacheKey(passage: "hola", context: "hola amigo", sourceLanguage: es, targetLanguage: en)
    #expect(a != b)
}
