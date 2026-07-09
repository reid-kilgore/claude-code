import Foundation

/// How a card prompts for its answer.
///
/// Recall types are the "harder gates": the user must produce or select the
/// correct answer, so an unlock can't be earned by mashing alone. Gate piles
/// mix modes freely but guarantee a minimum of recall cards
/// (`UnlockPolicy.minimumRecallCards`).
public enum AnswerMode: String, Codable, Sendable, CaseIterable {
    /// Classic Anki-style self-graded reveal (Again / Good). Allowed everywhere,
    /// including gate piles — cheating through these is tolerated by design.
    case selfGraded
    /// Pick the correct answer among generated distractors.
    case multipleChoice
    /// Type the answer; graded by normalized comparison with tolerance.
    case typed
}

/// The FSRS learning phase of a card.
public enum CardPhase: String, Codable, Sendable {
    case new
    case learning
    case review
    case relearning
}

/// User's answer rating, Anki-style. Raw values match FSRS grade numbering.
public enum Rating: Int, Codable, Sendable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
}

/// FSRS memory state carried by every non-new card.
public struct MemoryState: Codable, Equatable, Sendable {
    /// Stability: days for retrievability to fall from 100% to 90%.
    public var stability: Double
    /// Difficulty in [1, 10].
    public var difficulty: Double

    public init(stability: Double, difficulty: Double) {
        self.stability = stability
        self.difficulty = difficulty
    }
}

/// A single flashcard. In an Anki-like model this is a *card* (a note can
/// produce several cards); the MVP keeps a 1:1 note:card mapping.
public struct Card: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var deckID: UUID
    public var front: String
    public var back: String
    /// Alternative accepted answers for typed grading (e.g. "USA", "United States").
    public var alternativeAnswers: [String]
    public var answerMode: AnswerMode

    // Scheduling state
    public var phase: CardPhase
    public var memory: MemoryState?
    /// Index into the learning/relearning steps while in those phases.
    public var stepIndex: Int
    public var due: Date
    public var lastReview: Date?
    public var lapses: Int
    public var reps: Int
    public var suspended: Bool

    public init(
        id: UUID = UUID(),
        deckID: UUID,
        front: String,
        back: String,
        alternativeAnswers: [String] = [],
        answerMode: AnswerMode = .multipleChoice,
        phase: CardPhase = .new,
        memory: MemoryState? = nil,
        stepIndex: Int = 0,
        due: Date = .distantPast,
        lastReview: Date? = nil,
        lapses: Int = 0,
        reps: Int = 0,
        suspended: Bool = false
    ) {
        self.id = id
        self.deckID = deckID
        self.front = front
        self.back = back
        self.alternativeAnswers = alternativeAnswers
        self.answerMode = answerMode
        self.phase = phase
        self.memory = memory
        self.stepIndex = stepIndex
        self.due = due
        self.lastReview = lastReview
        self.lapses = lapses
        self.reps = reps
        self.suspended = suspended
    }

    public func isDue(at date: Date) -> Bool {
        !suspended && due <= date
    }
}

public struct Deck: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var newCardsPerDay: Int
    /// Desired retention passed to FSRS when scheduling this deck's cards.
    public var requestedRetention: Double

    public init(
        id: UUID = UUID(),
        name: String,
        newCardsPerDay: Int = 20,
        requestedRetention: Double = 0.9
    ) {
        self.id = id
        self.name = name
        self.newCardsPerDay = newCardsPerDay
        self.requestedRetention = requestedRetention
    }
}

/// Immutable record of one review, for stats and future FSRS weight optimization.
public struct ReviewLog: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var cardID: UUID
    public var reviewedAt: Date
    public var rating: Rating
    public var phaseBefore: CardPhase
    public var scheduledDays: Double
    /// Whether this review happened inside an unlock-gate session.
    public var inGateSession: Bool

    public init(
        id: UUID = UUID(),
        cardID: UUID,
        reviewedAt: Date,
        rating: Rating,
        phaseBefore: CardPhase,
        scheduledDays: Double,
        inGateSession: Bool = false
    ) {
        self.id = id
        self.cardID = cardID
        self.reviewedAt = reviewedAt
        self.rating = rating
        self.phaseBefore = phaseBefore
        self.scheduledDays = scheduledDays
        self.inGateSession = inGateSession
    }
}
