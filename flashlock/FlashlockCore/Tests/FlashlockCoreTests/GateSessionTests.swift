import XCTest
@testable import FlashlockCore

final class GateSessionTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_767_225_600)
    let policy = UnlockPolicy(
        cardCount: 3, minutesGranted: 15,
        minimumRecallCards: 2, maxUnlocksPerDay: 2)

    private func correct() -> GradedAnswer { GradedAnswer(isCorrect: true) }
    private func wrong() -> GradedAnswer { GradedAnswer(isCorrect: false) }
    private func pile(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    func testClearingThePileCompletesAndPaysOut() {
        var session = GateSession(policy: policy, pile: pile(3), startedAt: start)
        XCTAssertNil(session.submit(correct(), at: start))
        XCTAssertNil(session.submit(correct(), at: start))
        XCTAssertEqual(session.remaining, 1)
        let credit = session.submit(correct(), at: start.addingTimeInterval(60))
        XCTAssertNotNil(credit)
        XCTAssertEqual(credit?.minutes, 15)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(credit?.expiresAt, start.addingTimeInterval(60 + 15 * 60))
    }

    func testMissedCardGoesToTheBackOfThePile() {
        let ids = pile(3)
        var session = GateSession(policy: policy, pile: ids, startedAt: start)
        XCTAssertEqual(session.currentCardID, ids[0])
        session.submit(wrong(), at: start)
        // Pile size unchanged; the missed card is now last, next card is up.
        XCTAssertEqual(session.remaining, 3)
        XCTAssertEqual(session.currentCardID, ids[1])
        XCTAssertEqual(session.missCount, 1)
        // Clear the two others; the missed card comes around again.
        session.submit(correct(), at: start)
        session.submit(correct(), at: start)
        XCTAssertEqual(session.currentCardID, ids[0])
        XCTAssertNotNil(session.submit(correct(), at: start))
    }

    func testMissesNeverGrowThePileOrThePayout() {
        var session = GateSession(policy: policy, pile: pile(2), startedAt: start)
        for _ in 0..<10 { session.submit(wrong(), at: start) }
        XCTAssertEqual(session.remaining, 2, "misses requeue, they don't add cards")
        XCTAssertEqual(session.status, .inProgress)
        session.submit(correct(), at: start)
        let credit = session.submit(correct(), at: start)
        XCTAssertEqual(credit?.minutes, 15, "payout is fixed regardless of misses")
    }

    func testSingleCardPileRepeatsUntilCorrect() {
        let ids = pile(1)
        var session = GateSession(policy: policy, pile: ids, startedAt: start)
        session.submit(wrong(), at: start)
        XCTAssertEqual(session.currentCardID, ids[0], "a lone missed card comes straight back")
        XCTAssertNotNil(session.submit(correct(), at: start))
    }

    func testCompletedSessionIgnoresFurtherAnswers() {
        var session = GateSession(policy: policy, pile: pile(1), startedAt: start)
        XCTAssertNotNil(session.submit(correct(), at: start))
        XCTAssertNil(session.submit(correct(), at: start), "no double payout")
        XCTAssertNil(session.currentCardID)
    }

    func testAbandon() {
        var session = GateSession(policy: policy, pile: pile(2), startedAt: start)
        session.submit(correct(), at: start)
        session.abandon()
        XCTAssertEqual(session.status, .abandoned)
        XCTAssertNil(session.submit(correct(), at: start))
        XCTAssertNil(session.currentCardID)
    }

    func testProgressCountsClearedCards() {
        var session = GateSession(policy: policy, pile: pile(4), startedAt: start)
        XCTAssertEqual(session.progress, 0)
        session.submit(correct(), at: start)
        XCTAssertEqual(session.progress, 0.25, accuracy: 1e-9)
        session.submit(wrong(), at: start)
        XCTAssertEqual(session.progress, 0.25, accuracy: 1e-9, "misses don't move progress")
    }

    // MARK: - Pile composition

    func testGatePileEnforcesRecallMinimum() {
        let deckID = UUID()
        let due = start.addingTimeInterval(-3600)
        // Five due self-graded cards, two recall cards further down the queue.
        var cards = (0..<5).map { i in
            Card(deckID: deckID, front: "sg\(i)", back: "a\(i)", answerMode: .selfGraded,
                 phase: .review, due: due)
        }
        cards.append(Card(deckID: deckID, front: "mc", back: "b1", answerMode: .multipleChoice,
                          phase: .review, due: start.addingTimeInterval(86_400)))
        cards.append(Card(deckID: deckID, front: "ty", back: "b2", answerMode: .typed,
                          phase: .new))

        let pile = ReviewQueue.gatePile(from: cards, count: 5, minimumRecall: 2, at: start)
        XCTAssertEqual(pile.count, 5)
        XCTAssertEqual(pile.filter { $0.answerMode != .selfGraded }.count, 2,
            "recall cards are swapped in to meet the minimum")
        XCTAssertEqual(pile.filter { $0.answerMode == .selfGraded }.count, 3,
            "self-graded cards still fill the rest of the pile")
    }

    func testGatePileWithOnlySelfGradedCardsStillFills() {
        let deckID = UUID()
        let cards = (0..<4).map { i in
            Card(deckID: deckID, front: "sg\(i)", back: "a\(i)", answerMode: .selfGraded,
                 phase: .review, due: start.addingTimeInterval(-60))
        }
        let pile = ReviewQueue.gatePile(from: cards, count: 3, minimumRecall: 2, at: start)
        XCTAssertEqual(pile.count, 3, "no recall cards exist — the pile fills anyway")
    }

    func testGatePilePrefersDueCards() {
        let deckID = UUID()
        let dueCard = Card(deckID: deckID, front: "due", back: "x", answerMode: .multipleChoice,
                           phase: .review, due: start.addingTimeInterval(-60))
        let laterCard = Card(deckID: deckID, front: "later", back: "y", answerMode: .multipleChoice,
                             phase: .review, due: start.addingTimeInterval(86_400))
        let pile = ReviewQueue.gatePile(from: [laterCard, dueCard], count: 1, minimumRecall: 1, at: start)
        XCTAssertEqual(pile.first?.front, "due")
    }

    // MARK: - Ledger

    func testLedgerActiveCreditWindow() {
        var ledger = UnlockLedger()
        let credit = TimeCredit(grantedAt: start, minutes: 15)
        ledger.record(credit)
        XCTAssertEqual(ledger.activeCredit(at: start.addingTimeInterval(60)), credit)
        XCTAssertNil(ledger.activeCredit(at: start.addingTimeInterval(16 * 60)),
            "credit expires after its window")
    }

    func testLedgerDailyCap() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var ledger = UnlockLedger()
        XCTAssertTrue(ledger.canStartSession(policy: policy, at: start, calendar: calendar))
        ledger.record(TimeCredit(grantedAt: start, minutes: 15))
        ledger.record(TimeCredit(grantedAt: start.addingTimeInterval(3600), minutes: 15))
        XCTAssertFalse(ledger.canStartSession(policy: policy, at: start.addingTimeInterval(7200), calendar: calendar),
            "two grants used, daily cap reached")
        let tomorrow = start.addingTimeInterval(86_400)
        XCTAssertTrue(ledger.canStartSession(policy: policy, at: tomorrow, calendar: calendar),
            "cap resets at midnight")
    }

    func testLedgerPrune() {
        var ledger = UnlockLedger()
        ledger.record(TimeCredit(grantedAt: start.addingTimeInterval(-30 * 86_400), minutes: 15))
        ledger.record(TimeCredit(grantedAt: start, minutes: 15))
        ledger.prune(before: start)
        XCTAssertEqual(ledger.credits.count, 1)
    }
}
