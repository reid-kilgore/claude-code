import XCTest
@testable import FlashlockCore

final class GateSessionTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_767_225_600)
    let policy = UnlockPolicy(
        requiredCorrect: 3, minutesGranted: 15,
        wrongAnswerPenalty: 1, maxRequiredCorrect: 6, maxUnlocksPerDay: 2)

    private func correct() -> GradedAnswer { GradedAnswer(isCorrect: true) }
    private func wrong() -> GradedAnswer { GradedAnswer(isCorrect: false) }

    func testCompletesAfterRequiredCorrect() {
        var session = GateSession(policy: policy, startedAt: start)
        XCTAssertNil(session.submit(correct(), at: start))
        XCTAssertNil(session.submit(correct(), at: start))
        XCTAssertEqual(session.remaining, 1)
        let credit = session.submit(correct(), at: start.addingTimeInterval(60))
        XCTAssertNotNil(credit)
        XCTAssertEqual(credit?.minutes, 15)
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(credit?.expiresAt, start.addingTimeInterval(60 + 15 * 60))
    }

    func testWrongAnswersRaiseTheBar() {
        var session = GateSession(policy: policy, startedAt: start)
        session.submit(wrong(), at: start)
        session.submit(wrong(), at: start)
        XCTAssertEqual(session.requiredCorrect, 5, "3 base + 2 penalties")
        for _ in 0..<4 { XCTAssertNil(session.submit(correct(), at: start)) }
        XCTAssertNotNil(session.submit(correct(), at: start))
    }

    func testPenaltyIsCapped() {
        var session = GateSession(policy: policy, startedAt: start)
        for _ in 0..<20 { session.submit(wrong(), at: start) }
        XCTAssertEqual(session.requiredCorrect, 6, "penalties cap at maxRequiredCorrect")
        XCTAssertEqual(session.status, .inProgress, "a bad run stays finishable")
    }

    func testGuessingHasNegativeExpectedValue() {
        // With 4-option multiple choice (p=0.25) and +1 required per miss,
        // random guessing should rarely finish a 3-card gate quickly: each
        // guess yields 0.25 correct but 0.75 penalties in expectation. Simulate
        // 50 guessers; knowing the answers costs 3 taps — guessing must almost
        // never finish within 12.
        var fastCompletions = 0
        var totalTaps = 0
        for seed in 0..<50 {
            var session = GateSession(policy: policy, startedAt: start)
            var generator = SeededGenerator(seed: UInt64(seed))
            var taps = 0
            while session.status == .inProgress && taps < 500 {
                let hit = Double.random(in: 0..<1, using: &generator) < 0.25
                session.submit(GradedAnswer(isCorrect: hit), at: start)
                taps += 1
            }
            totalTaps += taps
            if session.status == .completed && taps <= 12 { fastCompletions += 1 }
        }
        XCTAssertLessThan(fastCompletions, 10,
            "guessing should almost never beat the gate as fast as knowing the answers")
        XCTAssertGreaterThan(totalTaps / 50, 12,
            "guessing costs several times more taps on average than the 3 required answers")
    }

    func testCompletedSessionIgnoresFurtherAnswers() {
        var session = GateSession(policy: policy, startedAt: start)
        for _ in 0..<3 { session.submit(correct(), at: start) }
        XCTAssertEqual(session.status, .completed)
        XCTAssertNil(session.submit(correct(), at: start), "no double payout")
    }

    func testAbandon() {
        var session = GateSession(policy: policy, startedAt: start)
        session.submit(correct(), at: start)
        session.abandon()
        XCTAssertEqual(session.status, .abandoned)
        XCTAssertNil(session.submit(correct(), at: start))
    }

    func testProgress() {
        var session = GateSession(policy: policy, startedAt: start)
        XCTAssertEqual(session.progress, 0)
        session.submit(correct(), at: start)
        XCTAssertEqual(session.progress, 1.0 / 3.0, accuracy: 1e-9)
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
