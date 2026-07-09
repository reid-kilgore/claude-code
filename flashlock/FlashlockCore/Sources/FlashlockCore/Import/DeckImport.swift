import Foundation

/// The on-disk interchange format for getting cards into Flashlock — a small
/// JSON file produced by `scripts/apkg_to_flashlock.py` from an Anki .apkg
/// export (or written by hand). Example:
///
///     {
///       "format": "flashlock-deck-v1",
///       "name": "Spanish B1",
///       "cards": [
///         { "guid": "f8ilJ2ax(K", "front": "la manzana", "back": "apple",
///           "alternativeAnswers": [], "answerMode": "selfGraded" }
///       ]
///     }
public struct DeckImportFile: Codable, Equatable, Sendable {
    public static let currentFormat = "flashlock-deck-v1"

    public struct ImportCard: Codable, Equatable, Sendable {
        /// Stable note identity (Anki note guid); the sync key across imports.
        public var guid: String
        public var front: String
        public var back: String
        public var alternativeAnswers: [String]?
        public var answerMode: AnswerMode?

        public init(
            guid: String, front: String, back: String,
            alternativeAnswers: [String]? = nil, answerMode: AnswerMode? = nil
        ) {
            self.guid = guid
            self.front = front
            self.back = back
            self.alternativeAnswers = alternativeAnswers
            self.answerMode = answerMode
        }
    }

    public var format: String
    public var name: String
    public var cards: [ImportCard]

    public init(name: String, cards: [ImportCard]) {
        self.format = Self.currentFormat
        self.name = name
        self.cards = cards
    }

    public enum ImportError: Error, Equatable {
        case unsupportedFormat(String)
        case emptyDeck
    }

    public static func decode(from data: Data) throws -> DeckImportFile {
        let file = try JSONDecoder().decode(DeckImportFile.self, from: data)
        guard file.format == currentFormat else {
            throw ImportError.unsupportedFormat(file.format)
        }
        guard !file.cards.isEmpty else { throw ImportError.emptyDeck }
        return file
    }
}

/// Merges an import file into an existing deck's cards, keyed by `guid`.
///
/// Sync semantics (deliberately simple, personal-use):
///  - unknown guid → new card (starts unscheduled in the `.new` phase)
///  - known guid with changed text → front/back/alternatives/mode updated,
///    **scheduling state untouched**
///  - known guid, identical content → unchanged
///  - card present locally but absent from the file → left alone (re-importing
///    a filtered/partial export never deletes anything)
public enum DeckMerger {
    public struct Result: Equatable, Sendable {
        public var added: Int
        public var updated: Int
        public var unchanged: Int
        /// The deck's full card list after the merge.
        public var cards: [Card]
    }

    public static func merge(
        _ file: DeckImportFile,
        into deckID: UUID,
        existingCards: [Card]
    ) -> Result {
        var byGUID: [String: Int] = [:]
        for (index, card) in existingCards.enumerated() {
            if let guid = card.sourceGUID { byGUID[guid] = index }
        }

        var cards = existingCards
        var added = 0, updated = 0, unchanged = 0

        for imported in file.cards {
            let alternatives = imported.alternativeAnswers ?? []
            let mode = imported.answerMode ?? .selfGraded

            if let index = byGUID[imported.guid] {
                var card = cards[index]
                let changed = card.front != imported.front
                    || card.back != imported.back
                    || card.alternativeAnswers != alternatives
                    || card.answerMode != mode
                if changed {
                    card.front = imported.front
                    card.back = imported.back
                    card.alternativeAnswers = alternatives
                    card.answerMode = mode
                    cards[index] = card
                    updated += 1
                } else {
                    unchanged += 1
                }
            } else {
                cards.append(Card(
                    deckID: deckID,
                    front: imported.front,
                    back: imported.back,
                    alternativeAnswers: alternatives,
                    answerMode: mode,
                    sourceGUID: imported.guid
                ))
                added += 1
            }
        }
        return Result(added: added, updated: updated, unchanged: unchanged, cards: cards)
    }
}
