import XCTest
@testable import FlashlockCore

/// Qualitative invariants of the scheduler, independent of exact weights.
final class FSRSPropertyTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_767_225_600)
    let scheduler = FSRS(enableFuzzing: false)

    private func newCard() -> Card {
        Card(deckID: UUID(), front: "f", back: "b")
    }

    /// Answer Good at every due date; the card graduates and intervals grow.
    func testIntervalsGrowUnderGood() {
        var card = newCard()
        var now = start
        var previousInterval: TimeInterval = 0
        for i in 0..<8 {
            (card, _) = scheduler.review(card: card, rating: .good, at: now)
            let interval = card.due.timeIntervalSince(now)
            if card.phase == .review, i >= 2 {
                XCTAssertGreaterThan(interval, previousInterval,
                    "review intervals should grow monotonically under Good")
            }
            previousInterval = interval
            now = card.due
        }
        XCTAssertEqual(card.phase, .review)
        XCTAssertGreaterThan(previousInterval, 30 * 86_400,
            "after 8 straight Good reviews the interval should exceed a month")
    }

    func testLearningStepsBeforeGraduation() {
        var card = newCard()
        // First Good: 1m -> 10m step.
        (card, _) = scheduler.review(card: card, rating: .good, at: start)
        XCTAssertEqual(card.phase, .learning)
        XCTAssertEqual(card.due.timeIntervalSince(start), 600, accuracy: 1)
        // Second Good graduates to review with a >= 1 day interval.
        (card, _) = scheduler.review(card: card, rating: .good, at: card.due)
        XCTAssertEqual(card.phase, .review)
        XCTAssertGreaterThanOrEqual(card.due.timeIntervalSince(start), 86_400 - 700)
    }

    func testEasyGraduatesImmediately() {
        var card = newCard()
        (card, _) = scheduler.review(card: card, rating: .easy, at: start)
        XCTAssertEqual(card.phase, .review)
    }

    func testAgainInReviewLapsesToRelearning() {
        var card = newCard()
        var now = start
        for _ in 0..<3 {
            (card, _) = scheduler.review(card: card, rating: .good, at: now)
            now = card.due
        }
        XCTAssertEqual(card.phase, .review)
        let stabilityBefore = card.memory!.stability
        let difficultyBefore = card.memory!.difficulty

        (card, _) = scheduler.review(card: card, rating: .again, at: now)
        XCTAssertEqual(card.phase, .relearning)
        XCTAssertEqual(card.lapses, 1)
        XCTAssertLessThan(card.memory!.stability, stabilityBefore,
            "a lapse must reduce stability")
        XCTAssertGreaterThan(card.memory!.difficulty, difficultyBefore,
            "a lapse must increase difficulty")
        XCTAssertEqual(card.due.timeIntervalSince(now), 600, accuracy: 1,
            "relearning step is 10 minutes")
    }

    func testLowerRetentionMeansLongerIntervals() {
        let relaxed = FSRS(desiredRetention: 0.8, enableFuzzing: false)
        XCTAssertGreaterThan(
            relaxed.nextIntervalDays(stability: 10),
            scheduler.nextIntervalDays(stability: 10))
        // At r = 0.9 the interval equals stability by construction.
        XCTAssertEqual(scheduler.nextIntervalDays(stability: 10), 10)
    }

    func testRetrievabilityDecaysOverTime() {
        var card = newCard()
        var now = start
        for _ in 0..<3 {
            (card, _) = scheduler.review(card: card, rating: .good, at: now)
            now = card.due
        }
        let r0 = scheduler.retrievability(of: card, at: card.lastReview!)
        let r1 = scheduler.retrievability(of: card, at: card.due)
        let r2 = scheduler.retrievability(of: card, at: card.due.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(r0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r1, 0.9, accuracy: 0.02, "due date targets desired retention")
        XCTAssertLessThan(r2, r1)
    }

    func testFuzzedIntervalStaysNearOriginal() {
        var generator = SeededGenerator(seed: 7)
        let scheduler = FSRS() // fuzzing on
        for days in [3, 10, 50, 365] {
            let interval = TimeInterval(days) * 86_400
            let fuzzed = scheduler.fuzzedInterval(interval, using: &generator)
            XCTAssertGreaterThan(fuzzed, interval * 0.8)
            XCTAssertLessThan(fuzzed, interval * 1.2)
        }
        // Short intervals are never fuzzed.
        let short = scheduler.fuzzedInterval(2 * 86_400, using: &generator)
        XCTAssertEqual(short, 2 * 86_400)
    }

    func testDifficultyStaysInBounds() {
        var card = newCard()
        var now = start
        for rating in [Rating.again, .again, .again, .again, .hard, .again, .again] {
            (card, _) = scheduler.review(card: card, rating: rating, at: now)
            now = card.due
            let d = card.memory!.difficulty
            XCTAssertGreaterThanOrEqual(d, 1.0)
            XCTAssertLessThanOrEqual(d, 10.0)
        }
    }
}
