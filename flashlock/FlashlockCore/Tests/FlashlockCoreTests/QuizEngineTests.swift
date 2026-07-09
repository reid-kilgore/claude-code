import XCTest
@testable import FlashlockCore

final class QuizEngineTests: XCTestCase {
    let deckID = UUID()
    let engine = QuizEngine()

    private func card(_ front: String, _ back: String, mode: AnswerMode = .multipleChoice,
                      alt: [String] = []) -> Card {
        Card(deckID: deckID, front: front, back: back, alternativeAnswers: alt, answerMode: mode)
    }

    private var capitals: [Card] {
        [
            card("France", "Paris"),
            card("Germany", "Berlin"),
            card("Italy", "Rome"),
            card("Spain", "Madrid"),
            card("Portugal", "Lisbon"),
            card("Austria", "Vienna"),
        ]
    }

    // MARK: - Normalization & edit distance

    func testNormalization() {
        XCTAssertEqual(AnswerNormalizer.normalize("  São   Paulo! "), "sao paulo")
        XCTAssertEqual(AnswerNormalizer.normalize("L'Hôpital"), "l hopital")
        XCTAssertEqual(AnswerNormalizer.normalize("USA"), "usa")
        XCTAssertEqual(AnswerNormalizer.normalize("42"), "42")
    }

    func testEditDistance() {
        XCTAssertEqual(AnswerNormalizer.editDistance("paris", "paris"), 0)
        XCTAssertEqual(AnswerNormalizer.editDistance("paris", "pari"), 1)
        XCTAssertEqual(AnswerNormalizer.editDistance("paris", "prais"), 1, "transposition counts as one edit")
        XCTAssertEqual(AnswerNormalizer.editDistance("paris", "london"), 6)
        XCTAssertEqual(AnswerNormalizer.editDistance("", "abc"), 3)
    }

    // MARK: - Multiple choice

    func testMultipleChoiceHasOneCorrectAndUniqueChoices() {
        let pool = capitals
        var generator = SeededGenerator(seed: 1)
        let question = engine.makeQuestion(for: pool[0], pool: pool, using: &generator)
        guard case let .multipleChoice(cardID, front, choices, correctIndex) = question else {
            return XCTFail("expected multiple choice, got \(question)")
        }
        XCTAssertEqual(cardID, pool[0].id)
        XCTAssertEqual(front, "France")
        XCTAssertEqual(choices.count, 4)
        XCTAssertEqual(choices[correctIndex], "Paris")
        XCTAssertEqual(Set(choices).count, choices.count, "choices must be distinct")
    }

    func testMultipleChoiceIsDeterministicPerSeed() {
        let pool = capitals
        var g1 = SeededGenerator(seed: 42)
        var g2 = SeededGenerator(seed: 42)
        XCTAssertEqual(
            engine.makeQuestion(for: pool[1], pool: pool, using: &g1),
            engine.makeQuestion(for: pool[1], pool: pool, using: &g2))
    }

    func testTinyPoolFallsBackToTyped() {
        let lonely = [card("France", "Paris"), card("Germany", "Berlin")]
        var generator = SeededGenerator(seed: 3)
        let question = engine.makeQuestion(for: lonely[0], pool: lonely, using: &generator)
        guard case .typed = question else {
            return XCTFail("with < 2 possible distractors the question must fall back to typed")
        }
    }

    func testForceRecallUpgradesSelfGraded() {
        var pool = capitals
        pool[0].answerMode = .selfGraded
        var generator = SeededGenerator(seed: 4)
        let free = engine.makeQuestion(for: pool[0], pool: pool, using: &generator)
        guard case .selfGraded = free else { return XCTFail("expected selfGraded") }
        let gated = engine.makeQuestion(for: pool[0], pool: pool, forceRecall: true, using: &generator)
        if case .selfGraded = gated {
            XCTFail("gate sessions must never serve self-graded questions")
        }
    }

    func testDistractorsExcludeAnswersEqualToCorrect() {
        // Two cards share the same answer text; it must never appear as a distractor.
        var pool = capitals
        pool.append(card("Capital of France?", "Paris"))
        var generator = SeededGenerator(seed: 5)
        let distractors = engine.selectDistractors(for: pool[0], from: pool, using: &generator)
        XCTAssertFalse(distractors.map(AnswerNormalizer.normalize).contains("paris"))
    }

    func testGradeMultipleChoice() {
        var generator = SeededGenerator(seed: 6)
        let question = engine.makeQuestion(for: capitals[0], pool: capitals, using: &generator)
        guard case let .multipleChoice(_, _, _, correctIndex) = question else {
            return XCTFail()
        }
        XCTAssertTrue(engine.gradeMultipleChoice(question: question, selectedIndex: correctIndex).isCorrect)
        let wrongIndex = (correctIndex + 1) % 4
        let wrong = engine.gradeMultipleChoice(question: question, selectedIndex: wrongIndex)
        XCTAssertFalse(wrong.isCorrect)
        XCTAssertEqual(wrong.suggestedRating, .again)
        XCTAssertFalse(engine.gradeMultipleChoice(question: question, selectedIndex: 99).isCorrect)
    }

    // MARK: - Typed grading

    func testTypedExactAndNormalizedMatch() {
        let c = card("Capital of France", "Paris", mode: .typed)
        XCTAssertTrue(engine.gradeTyped(card: c, input: "Paris").isCorrect)
        XCTAssertTrue(engine.gradeTyped(card: c, input: "  paris ").isCorrect)
        XCTAssertFalse(engine.gradeTyped(card: c, input: "").isCorrect)
        XCTAssertFalse(engine.gradeTyped(card: c, input: "London").isCorrect)
    }

    func testTypedAlternativeAnswers() {
        let c = card("Largest US state", "Alaska", mode: .typed, alt: ["AK"])
        XCTAssertTrue(engine.gradeTyped(card: c, input: "ak").isCorrect)
    }

    func testTypedFuzzyToleranceOnLongAnswers() {
        let c = card("Author of Don Quixote", "Cervantes", mode: .typed)
        let graded = engine.gradeTyped(card: c, input: "Cervantez")
        XCTAssertTrue(graded.isCorrect)
        XCTAssertTrue(graded.wasFuzzyMatch)
        XCTAssertEqual(graded.suggestedRating, .hard, "fuzzy matches auto-grade as Hard")
    }

    func testTypedShortAnswersRequireExactMatch() {
        let c = card("2+2", "4", mode: .typed)
        XCTAssertFalse(engine.gradeTyped(card: c, input: "5").isCorrect)
        let au = card("Gold symbol", "Au", mode: .typed)
        XCTAssertFalse(engine.gradeTyped(card: au, input: "Ag").isCorrect,
            "short answers must not fuzzy-match")
    }
}
