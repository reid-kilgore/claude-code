import Foundation

/// A rendered question for one card, in the mode the card (or the gate) requires.
public enum QuizQuestion: Equatable, Sendable {
    case selfGraded(cardID: UUID, front: String, back: String)
    case multipleChoice(cardID: UUID, front: String, choices: [String], correctIndex: Int)
    case typed(cardID: UUID, front: String)
}

/// Result of grading one answer.
public struct GradedAnswer: Equatable, Sendable {
    public var isCorrect: Bool
    /// True when a typed answer matched only within the edit-distance tolerance;
    /// the UI can surface "close — check the exact spelling".
    public var wasFuzzyMatch: Bool
    /// Suggested SRS rating for auto-grading recall answers: wrong → .again,
    /// fuzzy → .hard, exact → .good. Self-graded cards ignore this.
    public var suggestedRating: Rating

    public init(isCorrect: Bool, wasFuzzyMatch: Bool = false) {
        self.isCorrect = isCorrect
        self.wasFuzzyMatch = wasFuzzyMatch
        self.suggestedRating = isCorrect ? (wasFuzzyMatch ? .hard : .good) : .again
    }
}

public struct QuizConfig: Sendable {
    /// Total options shown for multiple choice (1 correct + N-1 distractors).
    public var choiceCount: Int
    /// Max edit distance accepted for typed answers, as a fraction of answer
    /// length (Anki-like leniency). 0 disables fuzz entirely.
    public var typedTolerance: Double
    /// Minimum answer length before any fuzzy tolerance applies — short answers
    /// like "7" or "au" must be exact.
    public var minLengthForFuzz: Int

    public init(choiceCount: Int = 4, typedTolerance: Double = 0.2, minLengthForFuzz: Int = 5) {
        self.choiceCount = choiceCount
        self.typedTolerance = typedTolerance
        self.minLengthForFuzz = minLengthForFuzz
    }
}

/// Builds questions and grades answers. Stateless; pass a seeded generator for
/// deterministic tests.
public struct QuizEngine: Sendable {
    public var config: QuizConfig

    public init(config: QuizConfig = QuizConfig()) {
        self.config = config
    }

    // MARK: - Question generation

    /// Renders `card` as a question. `pool` supplies distractor candidates for
    /// multiple choice — normally the rest of the card's deck.
    /// `forceRecall` upgrades self-graded cards to multiple choice for callers
    /// that want every question objectively verifiable; the standard gate flow
    /// serves cards in their own mode and relies on the pile's recall minimum
    /// instead.
    public func makeQuestion<G: RandomNumberGenerator>(
        for card: Card,
        pool: [Card],
        forceRecall: Bool = false,
        using generator: inout G
    ) -> QuizQuestion {
        var mode = card.answerMode
        if forceRecall, mode == .selfGraded {
            mode = .multipleChoice
        }
        switch mode {
        case .selfGraded:
            return .selfGraded(cardID: card.id, front: card.front, back: card.back)
        case .typed:
            return .typed(cardID: card.id, front: card.front)
        case .multipleChoice:
            let distractors = selectDistractors(for: card, from: pool, using: &generator)
            // Not enough distinct wrong answers in the deck: fall back to typed
            // rather than a degenerate 1-2 option question.
            guard distractors.count >= 2 else {
                return .typed(cardID: card.id, front: card.front)
            }
            var choices = distractors + [card.back]
            choices.shuffle(using: &generator)
            let correctIndex = choices.firstIndex(of: card.back)!
            return .multipleChoice(
                cardID: card.id, front: card.front,
                choices: choices, correctIndex: correctIndex)
        }
    }

    /// Picks plausible wrong answers: prefers answers similar to the correct one
    /// (closer edit distance on normalized text ranks higher), with a random
    /// jitter so repeat encounters don't always show the identical option set.
    func selectDistractors<G: RandomNumberGenerator>(
        for card: Card, from pool: [Card], using generator: inout G
    ) -> [String] {
        let correctNorm = AnswerNormalizer.normalize(card.back)
        var seen: Set<String> = [correctNorm]
        var candidates: [(answer: String, score: Double)] = []

        for other in pool where other.id != card.id {
            let norm = AnswerNormalizer.normalize(other.back)
            guard !norm.isEmpty, !seen.contains(norm) else { continue }
            seen.insert(norm)
            let distance = AnswerNormalizer.editDistance(correctNorm, norm)
            let similarity = 1.0 / (1.0 + Double(distance))
            let jitter = Double.random(in: 0..<0.35, using: &generator)
            candidates.append((other.back, similarity + jitter))
        }

        return candidates
            .sorted { $0.score > $1.score }
            .prefix(config.choiceCount - 1)
            .map(\.answer)
    }

    // MARK: - Grading

    public func gradeMultipleChoice(question: QuizQuestion, selectedIndex: Int) -> GradedAnswer {
        guard case let .multipleChoice(_, _, choices, correctIndex) = question,
              choices.indices.contains(selectedIndex) else {
            return GradedAnswer(isCorrect: false)
        }
        return GradedAnswer(isCorrect: selectedIndex == correctIndex)
    }

    public func gradeTyped(card: Card, input: String) -> GradedAnswer {
        let normalizedInput = AnswerNormalizer.normalize(input)
        guard !normalizedInput.isEmpty else { return GradedAnswer(isCorrect: false) }

        let accepted = ([card.back] + card.alternativeAnswers).map(AnswerNormalizer.normalize)

        if accepted.contains(normalizedInput) {
            return GradedAnswer(isCorrect: true)
        }
        guard config.typedTolerance > 0 else { return GradedAnswer(isCorrect: false) }

        for answer in accepted where answer.count >= config.minLengthForFuzz {
            let allowed = Int(Double(answer.count) * config.typedTolerance)
            guard allowed > 0 else { continue }
            if AnswerNormalizer.editDistance(normalizedInput, answer) <= allowed {
                return GradedAnswer(isCorrect: true, wasFuzzyMatch: true)
            }
        }
        return GradedAnswer(isCorrect: false)
    }
}
