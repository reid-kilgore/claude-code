import Foundation

/// Builds the ordered set of cards to study right now, Anki-style:
/// learning/relearning cards first (most time-sensitive), then due reviews,
/// then new cards up to the deck's daily limit.
public enum ReviewQueue {
    public static func build(
        from cards: [Card],
        deck: Deck,
        newCardsIntroducedToday: Int,
        at date: Date
    ) -> [Card] {
        let active = cards.filter { !$0.suspended && $0.deckID == deck.id }

        let learning = active
            .filter { ($0.phase == .learning || $0.phase == .relearning) && $0.due <= date }
            .sorted { $0.due < $1.due }
        let review = active
            .filter { $0.phase == .review && $0.due <= date }
            .sorted { $0.due < $1.due }
        let newAllowance = max(deck.newCardsPerDay - newCardsIntroducedToday, 0)
        let fresh = active
            .filter { $0.phase == .new }
            .prefix(newAllowance)

        return learning + review + Array(fresh)
    }

    /// Builds the pile for an unlock-gate session: `count` cards, due cards
    /// first (so gated reviews advance the user's real study schedule), padded
    /// with not-yet-due review cards and then new cards when the due queue is
    /// short.
    ///
    /// Cards keep their own answer mode in the gate — self-graded cards are
    /// allowed (cheating through those is accepted) — but the pile includes at
    /// least `minimumRecall` recall-mode cards when the collection has them,
    /// so clearing it always takes some genuine recall.
    ///
    /// IMPORTANT: only the FIRST answer on a card that was actually due should
    /// be fed back into FSRS as a graded review (check `card.isDue(at:)`).
    /// Requeued re-asks and padding cards are quiz-only — repeatedly grading
    /// them would corrupt their memory state via the same-day update path.
    public static func gatePile(
        from cards: [Card],
        count: Int,
        minimumRecall: Int,
        at date: Date
    ) -> [Card] {
        let active = cards.filter { !$0.suspended }
        // Candidates in priority order: due, then not-yet-due review, then new.
        let due = active.filter { $0.phase != .new && $0.isDue(at: date) }
            .sorted { $0.due < $1.due }
        let upcoming = active.filter { $0.phase == .review && !$0.isDue(at: date) }
            .sorted { $0.due < $1.due }
        let fresh = active.filter { $0.phase == .new }
        let ranked = due + upcoming + fresh

        var pile = Array(ranked.prefix(count))

        // Swap in recall cards (from the same priority order) until the
        // minimum is met or the collection runs out of them.
        let isRecall = { (c: Card) in c.answerMode != .selfGraded }
        var recallCount = pile.filter(isRecall).count
        if recallCount < minimumRecall {
            let reserves = ranked.filter { candidate in
                isRecall(candidate) && !pile.contains { $0.id == candidate.id }
            }
            var reserveIndex = 0
            for i in pile.indices.reversed() where recallCount < minimumRecall {
                guard reserveIndex < reserves.count else { break }
                if !isRecall(pile[i]) {
                    pile[i] = reserves[reserveIndex]
                    reserveIndex += 1
                    recallCount += 1
                }
            }
        }
        return pile
    }
}
