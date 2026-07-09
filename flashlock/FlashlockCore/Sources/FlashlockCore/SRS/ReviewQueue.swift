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

    /// Cards eligible for an unlock-gate session: prefer due cards so gated
    /// reviews advance the user's real study schedule; pad with not-yet-due
    /// review cards if the due queue is short.
    ///
    /// IMPORTANT: only answers on cards that were actually due should be fed
    /// back into FSRS as graded reviews (check `card.isDue(at:)` before calling
    /// `FSRS.review`). Padding cards are quiz-only — repeatedly grading not-due
    /// cards would corrupt their memory state via the same-day update path.
    public static func gatePool(
        from cards: [Card],
        minimumCount: Int,
        at date: Date
    ) -> [Card] {
        let active = cards.filter { !$0.suspended }
        var pool = active.filter { $0.phase != .new && $0.isDue(at: date) }
            .sorted { $0.due < $1.due }

        if pool.count < minimumCount {
            let padding = active
                .filter { card in card.phase == .review && !pool.contains(where: { $0.id == card.id }) }
                .sorted { $0.due < $1.due }
                .prefix(minimumCount - pool.count)
            pool.append(contentsOf: padding)
        }
        if pool.count < minimumCount {
            let fresh = active.filter { $0.phase == .new }.prefix(minimumCount - pool.count)
            pool.append(contentsOf: fresh)
        }
        return pool
    }
}
