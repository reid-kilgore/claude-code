import FlashlockCore
import Foundation

/// Drives one "clear the pile to unlock" session (docs/02-architecture.md
/// §2.3): builds the pile via `ReviewQueue.gatePile`, serves every card in its
/// OWN answer mode — self-graded cards are allowed in the gate (cheating
/// through those is accepted by design; the pile's recall minimum keeps some
/// genuine recall in every unlock) — and on completion records the TimeCredit,
/// lifts the shield, and schedules re-lock. Missed cards go to the back of the
/// pile and come around again until answered correctly.
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
    private var currentCard: Card?
    /// Cards whose first attempt has been consumed. Only the FIRST answer per
    /// card feeds FSRS (and only if the card was due); requeued re-asks and
    /// padding cards are quiz-only — repeatedly grading them would corrupt
    /// their memory state via the same-day update path (ReviewQueue docs).
    private var gradedCardIDs: Set<UUID> = []

    init(cardStore: CardStore, sharedStore: SharedStore, now: Date = Date()) {
        self.cardStore = cardStore
        self.sharedStore = sharedStore
        let policy = sharedStore.unlockPolicy

        guard sharedStore.ledger.canStartSession(policy: policy, at: now) else {
            session = GateSession(policy: policy, pile: [], startedAt: now)
            blockedReason = "You've used all of today's unlocks. Try again tomorrow."
            return
        }

        let pile = ReviewQueue.gatePile(
            from: cardStore.cards,
            count: policy.cardCount,
            minimumRecall: policy.minimumRecallCards,
            at: now
        )
        session = GateSession(policy: policy, pile: pile.map(\.id), startedAt: now)
        guard !pile.isEmpty else {
            blockedReason = "Add some flashcards before you can earn time back."
            return
        }
        advance()
    }

    // MARK: - Answers

    /// Self-graded cards in the gate offer exactly two honesty buttons:
    /// Again (missed — back of the pile) and Good (cleared).
    func submitSelfGraded(_ rating: Rating) {
        guard let card = currentCard else { return }
        let now = Date()
        let graded = GradedAnswer(isCorrect: rating != .again)
        gradeFirstAttempt(card: card, rating: rating, at: now)

        if let credit = session.submit(graded, at: now) {
            complete(with: credit, now: now)
        } else if graded.isCorrect {
            // The reveal already showed the answer; no feedback screen needed.
            advance()
        } else {
            feedback = .requeued(correctAnswer: card.back)
        }
    }

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
        gradeFirstAttempt(card: card, rating: graded.suggestedRating, at: now)

        if graded.isCorrect {
            feedback = graded.wasFuzzyMatch ? .fuzzy(correctAnswer: card.back) : .correct
        } else {
            feedback = .requeued(correctAnswer: card.back)
        }

        if let credit = session.submit(graded, at: now) {
            complete(with: credit, now: now)
        }
    }

    private func gradeFirstAttempt(card: Card, rating: Rating, at now: Date) {
        guard !gradedCardIDs.contains(card.id) else { return }
        gradedCardIDs.insert(card.id)
        guard card.isDue(at: now) else { return }

        let fsrs = FSRS(
            desiredRetention: cardStore.deck(withID: card.deckID)?.requestedRetention ?? 0.9
        )
        let result = fsrs.review(card: card, rating: rating, at: now, inGateSession: true)
        cardStore.apply(result.card, log: result.log)
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

    /// Serves the pile's front card (from `session.currentCardID`) in the
    /// card's own answer mode.
    private func advance() {
        feedback = nil
        guard let cardID = session.currentCardID,
              let card = cardStore.cards.first(where: { $0.id == cardID }) else {
            currentCard = nil
            question = nil
            return
        }
        currentCard = card

        var generator = SystemRandomNumberGenerator()
        question = engine.makeQuestion(
            for: card,
            pool: cardStore.cards.filter { $0.deckID == card.deckID },
            using: &generator
        )
    }
}
