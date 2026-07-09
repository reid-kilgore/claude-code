import XCTest
@testable import FlashlockCore

final class DeckImportTests: XCTestCase {
    let deckID = UUID()

    private func file(_ cards: [DeckImportFile.ImportCard]) -> DeckImportFile {
        DeckImportFile(name: "Spanish", cards: cards)
    }

    func testDecodeValidatesFormatAndContent() throws {
        let good = try JSONEncoder().encode(file([.init(guid: "g1", front: "f", back: "b")]))
        XCTAssertNoThrow(try DeckImportFile.decode(from: good))

        var wrongFormat = file([.init(guid: "g1", front: "f", back: "b")])
        wrongFormat.format = "flashlock-deck-v99"
        let wrongData = try JSONEncoder().encode(wrongFormat)
        XCTAssertThrowsError(try DeckImportFile.decode(from: wrongData)) { error in
            XCTAssertEqual(error as? DeckImportFile.ImportError, .unsupportedFormat("flashlock-deck-v99"))
        }

        let empty = try JSONEncoder().encode(file([]))
        XCTAssertThrowsError(try DeckImportFile.decode(from: empty)) { error in
            XCTAssertEqual(error as? DeckImportFile.ImportError, .emptyDeck)
        }
    }

    func testFirstImportAddsEverythingAsNew() {
        let result = DeckMerger.merge(
            file([
                .init(guid: "g1", front: "la manzana", back: "apple"),
                .init(guid: "g2", front: "el perro", back: "dog", answerMode: .typed),
            ]),
            into: deckID, existingCards: [])
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.cards.count, 2)
        XCTAssertTrue(result.cards.allSatisfy { $0.phase == .new })
        XCTAssertEqual(result.cards[0].sourceGUID, "g1")
        XCTAssertEqual(result.cards[0].answerMode, .selfGraded, "mode defaults to selfGraded")
        XCTAssertEqual(result.cards[1].answerMode, .typed)
    }

    func testReimportUpdatesTextButPreservesSchedule() {
        // Simulate a studied card: it has memory state and a future due date.
        var studied = Card(deckID: deckID, front: "la manzana", back: "aple",
                           sourceGUID: "g1", phase: .review,
                           memory: MemoryState(stability: 12, difficulty: 4),
                           due: Date(timeIntervalSince1970: 2_000_000_000),
                           lastReview: Date(timeIntervalSince1970: 1_999_000_000))
        studied.reps = 9

        let result = DeckMerger.merge(
            file([.init(guid: "g1", front: "la manzana", back: "apple")]), // typo fixed
            into: deckID, existingCards: [studied])

        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.added, 0)
        let merged = result.cards[0]
        XCTAssertEqual(merged.back, "apple")
        XCTAssertEqual(merged.id, studied.id, "same card, not a replacement")
        XCTAssertEqual(merged.phase, .review)
        XCTAssertEqual(merged.memory, studied.memory)
        XCTAssertEqual(merged.due, studied.due)
        XCTAssertEqual(merged.reps, 9, "scheduling state survives a text update")
    }

    func testReimportWithIdenticalContentIsNoop() {
        let existing = Card(deckID: deckID, front: "f", back: "b", answerMode: .selfGraded,
                            sourceGUID: "g1")
        let result = DeckMerger.merge(
            file([.init(guid: "g1", front: "f", back: "b")]),
            into: deckID, existingCards: [existing])
        XCTAssertEqual(result.unchanged, 1)
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(result.cards, [existing])
    }

    func testCardsMissingFromTheFileAreNeverDeleted() {
        let kept = Card(deckID: deckID, front: "old", back: "card", sourceGUID: "gone")
        let manual = Card(deckID: deckID, front: "hand", back: "made") // no guid
        let result = DeckMerger.merge(
            file([.init(guid: "g-new", front: "n", back: "c")]),
            into: deckID, existingCards: [kept, manual])
        XCTAssertEqual(result.cards.count, 3)
        XCTAssertTrue(result.cards.contains(kept))
        XCTAssertTrue(result.cards.contains(manual))
    }

    func testManualCardsWithoutGUIDNeverMatchImports() {
        let manual = Card(deckID: deckID, front: "la manzana", back: "apple")
        let result = DeckMerger.merge(
            file([.init(guid: "g1", front: "la manzana", back: "apple")]),
            into: deckID, existingCards: [manual])
        XCTAssertEqual(result.added, 1, "identical text but no guid → separate card")
        XCTAssertEqual(result.cards.count, 2)
    }
}
