import FlashlockCore
import Foundation

/// Drives one "answer cards to unlock" session (docs/02-architecture.md §2.3):
/// serves the gate pool with `forceRecall` so every question is objectively
/// verifiable, feeds FSRS only for cards that were actually due, and on
/// completion records the TimeCredit, lifts the shield, and schedules re-lock.
@MainActor
final class GateViewModel: ObservableObject {
    @Published private(set) var session: GateSession
    @Published private(set) var question: QuizQuestion?
    @Published private(set) var feedback: AnswerFeedback?
    @Published private(set) var earnedCredit: TimeCredit?
    /// Non-nil when a session cannot run (daily cap hit, no cards).
    @Published private(set) var blockedReason: String?

    private let cardStore: CardStore
    private let sharedStore: SharedStore
    private let engine = QuizEngine()
    private var pool: [Card] = []
    private var poolIndex = 0
    private var currentCard: Card?

    init(cardStore: CardStore, sharedStore: SharedStore, now: Date = Date()) {
        self.cardStore = cardStore
        self.sharedStore = sharedStore
        let policy = sharedStore.unlockPolicy
        session = GateSession(policy: policy, startedAt: now)

        if !sharedStore.ledger.canStartSession(policy: policy, at: now) {
            blockedReason = "You've used all of today's unlocks. Try again tomorrow."
            return
        }
        pool = ReviewQueue.gatePool(
            from: cardStore.cards,
            minimumCount: policy.maxRequiredCorrect,
            at: now
        )
        if pool.isEmpty {
            blockedReason = "Add some flashcards before you can earn time back."
            return
        }
        advance()
    }

    // MARK: - Answers

    func submitChoice(_ index: Int) {
        guard let card = currentCard, let question else { return }
        submit(engine.gradeMultipleChoice(question: question, selectedIndex: index), card: card)
    }

    func submitTyped(_ input: String) {
        guard let card = currentCard else { return }
        submit(engine.gradeTyped(card: card, input: input), card: card)
    }

    func continueAfterFeedback() {
        guard earnedCredit == nil else { return }
        advance()
    }

    func abandon() {
        session.abandon()
    }

    // MARK: - Internals

    private func submit(_ graded: GradedAnswer, card: Card) {
        let now = Date()
        // Only answers on cards that were actually due feed FSRS; padding
        // cards are quiz-only — repeatedly grading not-due cards would corrupt
        // their memory state via the same-day update path (ReviewQueue docs).
        if card.isDue(at: now) {
            let fsrs = FSRS(
                desiredRetention: cardStore.deck(withID: card.deckID)?.requestedRetention ?? 0.9
            )
            let result = fsrs.review(
                card: card, rating: graded.suggestedRating, at: now, inGateSession: true
            )
            cardStore.apply(result.card, log: result.log)
        }

        if graded.isCorrect {
            feedback = graded.wasFuzzyMatch ? .fuzzy(correctAnswer: card.back) : .correct
        } else {
            feedback = .incorrect(correctAnswer: card.back)
        }

        if let credit = session.submit(graded, at: now) {
            complete(with: credit, now: now)
        }
    }

    private func complete(with credit: TimeCredit, now: Date) {
        var ledger = sharedStore.ledger
        ledger.record(credit)
        ledger.prune(before: now)
        sharedStore.ledger = ledger
        sharedStore.pendingGateRequest = nil

        // Lifts the shield: the reconciler now sees an active credit.
        ShieldStateReconciler.reconcile(now: now, store: sharedStore)

        if let selection = sharedStore.selection {
            // Best-effort: if registration throws, the reconciler still
            // re-locks at next foreground / next daily callback.
            try? RelockScheduler.scheduleRelock(for: credit, selection: selection, now: now)
        }
        earnedCredit = credit
    }

    private func advance() {
        feedback = nil
        guard session.status == .inProgress, !pool.isEmpty else { return }
        // Cycle through the pool; sessions can need more answers than there
        // are cards (wrong-answer penalties), so cards may repeat. Always take
        // the freshest copy so a mid-session FSRS update is respected.
        let stale = pool[poolIndex % pool.count]
        poolIndex += 1
        let card = cardStore.cards.first { $0.id == stale.id } ?? stale
        currentCard = card

        var generator = SystemRandomNumberGenerator()
        question = engine.makeQuestion(
            for: card,
            pool: cardStore.cards.filter { $0.deckID == card.deckID },
            forceRecall: true,
            using: &generator
        )
    }
}
