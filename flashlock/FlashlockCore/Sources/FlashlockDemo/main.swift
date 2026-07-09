import Foundation
import FlashlockCore

// Terminal simulation of the Flashlock loop: 30 days of a user studying a
// small deck and, on most days, hitting their screen-time limit and earning
// time back through gate sessions. Deterministic (seeded) so runs are
// reproducible. Run with: swift run flashlock-demo

var rng = SeededGenerator(seed: 2026)
let day: TimeInterval = 86_400
let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC

let deck = Deck(name: "World Capitals", newCardsPerDay: 4)
let facts: [(String, String)] = [
    ("France", "Paris"), ("Germany", "Berlin"), ("Italy", "Rome"),
    ("Spain", "Madrid"), ("Portugal", "Lisbon"), ("Austria", "Vienna"),
    ("Poland", "Warsaw"), ("Greece", "Athens"), ("Norway", "Oslo"),
    ("Sweden", "Stockholm"), ("Finland", "Helsinki"), ("Ireland", "Dublin"),
    ("Netherlands", "Amsterdam"), ("Belgium", "Brussels"), ("Denmark", "Copenhagen"),
    ("Czechia", "Prague"), ("Hungary", "Budapest"), ("Croatia", "Zagreb"),
]
var cards = facts.map { Card(deckID: deck.id, front: $0.0, back: $0.1) }

let scheduler = FSRS()
let quiz = QuizEngine()
let policy = UnlockPolicy(cardCount: 5, minutesGranted: 15,
                          minimumRecallCards: 2, maxUnlocksPerDay: 3)
var ledger = UnlockLedger()

// The simulated user recalls a studied card correctly 88% of the time.
func userAnswers(correctly probability: Double) -> Bool {
    Double.random(in: 0..<1, using: &rng) < probability
}

func indexOf(_ id: UUID) -> Int { cards.firstIndex { $0.id == id }! }

print("day | studied | due-left | gates | minutes-earned | avg-stability")
print("----+---------+----------+-------+----------------+--------------")

for dayNumber in 1...30 {
    let morning = start.addingTimeInterval(Double(dayNumber - 1) * day + 8 * 3600)

    // Free morning study: everything due plus the daily allotment of new cards.
    var newIntroduced = 0
    var studied = 0
    var queue = ReviewQueue.build(from: cards, deck: deck,
                                  newCardsIntroducedToday: 0, at: morning)
    var clock = morning
    while let next = queue.first, studied < 40 {
        queue.removeFirst()
        let i = indexOf(next.id)
        if cards[i].phase == .new { newIntroduced += 1 }
        let recalled = userAnswers(correctly: cards[i].phase == .new ? 0.55 : 0.88)
        let rating: Rating = recalled ? .good : .again
        (cards[i], _) = scheduler.review(card: cards[i], rating: rating, at: clock)
        studied += 1
        clock = clock.addingTimeInterval(20)
        // Cards that landed back in a learning step within the session come due
        // again before the session ends; pick them up.
        if queue.isEmpty {
            queue = ReviewQueue.build(from: cards, deck: deck,
                                      newCardsIntroducedToday: newIntroduced, at: clock)
                .filter { $0.due <= clock }
        }
    }

    // Evening: the user hits their limit on days 2+ and grinds gate sessions.
    var minutesEarned = 0
    var gates = 0
    if dayNumber >= 2 {
        let evening = start.addingTimeInterval(Double(dayNumber - 1) * day + 20 * 3600)
        var gateClock = evening
        let cravings = Int.random(in: 1...3, using: &rng)
        while ledger.canStartSession(policy: policy, at: gateClock), gates < cravings {
            let pile = ReviewQueue.gatePile(from: cards, count: policy.cardCount,
                                            minimumRecall: policy.minimumRecallCards,
                                            at: gateClock)
            guard !pile.isEmpty else { break }
            var session = GateSession(policy: policy, pile: pile.map(\.id),
                                      startedAt: gateClock)
            // Anki-style: a miss requeues the card; only the first attempt on a
            // due card feeds the real schedule (see ReviewQueue docs).
            var gradedCardIDs = Set<UUID>()
            while session.status == .inProgress, let cardID = session.currentCardID {
                let i = indexOf(cardID)
                let question = quiz.makeQuestion(for: cards[i], pool: cards, using: &rng)
                // Simulate: 82% correct on evening gate questions.
                let graded = GradedAnswer(isCorrect: userAnswers(correctly: 0.82))
                if cards[i].isDue(at: gateClock), !gradedCardIDs.contains(cardID) {
                    gradedCardIDs.insert(cardID)
                    (cards[i], _) = scheduler.review(
                        card: cards[i], rating: graded.suggestedRating,
                        at: gateClock, inGateSession: true)
                }
                _ = question // rendering is the app layer's job
                if let credit = session.submit(graded, at: gateClock) {
                    ledger.record(credit)
                    minutesEarned += credit.minutes
                }
                gateClock = gateClock.addingTimeInterval(15)
            }
            gates += 1
        }
    }

    let endOfDay = start.addingTimeInterval(Double(dayNumber) * day)
    let dueLeft = cards.filter { $0.phase != .new && $0.isDue(at: endOfDay) }.count
    let stabilities = cards.compactMap { $0.memory?.stability }
    let avgStability = stabilities.isEmpty ? 0 : stabilities.reduce(0, +) / Double(stabilities.count)
    print(String(format: "%3d | %7d | %8d | %5d | %14d | %11.1fd",
                 dayNumber, studied, dueLeft, gates, minutesEarned, avgStability))
}

let mature = cards.filter { ($0.memory?.stability ?? 0) > 21 }.count
print("\nAfter 30 days: \(cards.filter { $0.phase != .new }.count)/\(cards.count) cards in rotation, \(mature) mature (S > 21d).")
print("Unlocks granted: \(ledger.credits.count) (\(ledger.credits.map(\.minutes).reduce(0, +)) minutes earned).")
