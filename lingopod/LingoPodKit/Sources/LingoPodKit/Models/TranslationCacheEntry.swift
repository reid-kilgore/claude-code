// M0
// SwiftData model (architecture §4, verbatim field set; §11.1). See
// Podcast.swift for the note on why `public`/`init` are added beyond the
// architecture doc's pseudocode.
import Foundation
import SwiftData

@Model
public final class TranslationCacheEntry {
    /// `"\(sourceLang)|\(targetLang)|\(normalizedText)"`
    @Attribute(.unique) public var key: String
    public var sourceText: String
    public var translatedText: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var createdAt: Date

    public init(
        key: String,
        sourceText: String,
        translatedText: String,
        sourceLanguage: String,
        targetLanguage: String,
        createdAt: Date = .now
    ) {
        self.key = key
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.createdAt = createdAt
    }
}
