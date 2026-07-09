import FlashlockCore
import Foundation

/// Post-answer feedback shown before the user advances to the next question.
enum AnswerFeedback: Equatable {
    case correct
    /// Typed answer matched within edit-distance tolerance only.
    case fuzzy(correctAnswer: String)
    case incorrect(correctAnswer: String)
}

/// Free-study session over one deck: builds the Anki-style queue, renders one
/// question per card, and feeds every answer to FSRS.
@MainActor
final class StudyViewModel: ObservableObject {
    @Published private(set) var question: QuizQuestion?
    @Published private(set) var feedback: AnswerFeedback?
    @Published private(set) var reviewedCount = 0
    @Published private(set) var isFinished = false

    let deck: Deck

    private let cardStore: CardStore
    private let engine = QuizEngine()
    private let fsrs: FSRS
    private var queue: [Card] = []
    private var currentCard: Card?

    var remainingCount: Int {
        queue.count + (currentCard == nil ? 0 : 1)
    }

    init(cardStore: CardStore, deck: Deck, now: Date = Date()) {
        self.cardStore = cardStore
        self.deck = deck
        self.fsrs = FSRS(desiredRetention: deck.requestedRetention)
        queue = ReviewQueue.build(
            from: cardStore.cards,
            deck: deck,
            newCardsIntroducedToday: cardStore.newCardsIntroducedToday(at: now),
            at: now
        )
        advance()
    }

    // MARK: - Answers

    /// Self-graded reveal: the user picked their own rating, no feedback screen.
    func submitSelfGraded(_ rating: Rating) {
        guard let card = currentCard else { return }
        review(card: card, rating: rating)
        advance()
    }

    func submitChoice(_ index: Int) {
        guard let card = currentCard, let question else { return }
        finish(card: card, graded: engine.gradeMultipleChoice(question: question, selectedIndex: index))
    }

    func submitTyped(_ input: String) {
        guard let card = currentCard else { return }
        finish(card: card, graded: engine.gradeTyped(card: card, input: input))
    }

    func continueAfterFeedback() {
        advance()
    }

    // MARK: - Internals

    private func finish(card: Card, graded: GradedAnswer) {
        review(card: card, rating: graded.suggestedRating)
        if graded.isCorrect {
            feedback = graded.wasFuzzyMatch ? .fuzzy(correctAnswer: card.back) : .correct
        } else {
            feedback = .incorrect(correctAnswer: card.back)
        }
    }

    private func review(card: Card, rating: Rating) {
        let result = fsrs.review(card: card, rating: rating, at: Date())
        cardStore.apply(result.card, log: result.log)
        reviewedCount += 1
    }

    private func advance() {
        feedback = nil
        guard !queue.isEmpty else {
            currentCard = nil
            question = nil
            isFinished = true
            return
        }
        let card = queue.removeFirst()
        currentCard = card
        var generator = SystemRandomNumberGenerator()
        question = engine.makeQuestion(
            for: card,
            pool: cardStore.cards(in: deck),
            using: &generator
        )
    }
}
