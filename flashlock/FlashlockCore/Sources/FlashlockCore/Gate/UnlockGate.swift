import Foundation

/// User-configurable rule for how flashcards convert into screen time.
public struct UnlockPolicy: Codable, Equatable, Sendable {
    /// Cards in the gate pile. The pile must be fully cleared to earn the grant.
    public var cardCount: Int
    /// Minutes of access earned per cleared pile.
    public var minutesGranted: Int
    /// Minimum recall-mode (objectively graded) cards in the pile, when the
    /// collection has them. Self-graded cards are welcome in the pile — cheating
    /// through those is accepted — but these "harder gates" guarantee the unlock
    /// always takes some genuine recall.
    public var minimumRecallCards: Int
    /// Grants allowed per calendar day; nil = unlimited.
    public var maxUnlocksPerDay: Int?

    public init(
        cardCount: Int = 5,
        minutesGranted: Int = 15,
        minimumRecallCards: Int = 2,
        maxUnlocksPerDay: Int? = nil
    ) {
        self.cardCount = cardCount
        self.minutesGranted = minutesGranted
        self.minimumRecallCards = minimumRecallCards
        self.maxUnlocksPerDay = maxUnlocksPerDay
    }
}

/// A completed session's payout. The app layer applies it by lifting the shield
/// and scheduling a DeviceActivity re-lock at `expiresAt`.
public struct TimeCredit: Codable, Equatable, Sendable {
    public var grantedAt: Date
    public var minutes: Int
    public var expiresAt: Date

    public init(grantedAt: Date, minutes: Int) {
        self.grantedAt = grantedAt
        self.minutes = minutes
        self.expiresAt = grantedAt.addingTimeInterval(Double(minutes) * 60)
    }
}

/// State machine for one "clear the pile to unlock" session, with Anki-style
/// requeueing: a missed card goes to the back of the pile and comes around
/// again until it is answered correctly. The session completes — and pays out —
/// only when the pile is empty.
public struct GateSession: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case inProgress
        case completed
        case abandoned
    }

    public private(set) var policy: UnlockPolicy
    public private(set) var startedAt: Date
    /// Remaining card IDs; the first element is the card currently being asked.
    public private(set) var pile: [UUID]
    public let totalCards: Int
    public private(set) var missCount: Int = 0
    public private(set) var status: Status

    /// `pile` should come from `ReviewQueue.gatePile`; an empty pile completes
    /// immediately on the first submit-free check, so callers should not start
    /// sessions with no cards.
    public init(policy: UnlockPolicy, pile: [UUID], startedAt: Date) {
        self.policy = policy
        self.pile = pile
        self.totalCards = pile.count
        self.startedAt = startedAt
        self.status = pile.isEmpty ? .completed : .inProgress
    }

    public var currentCardID: UUID? {
        status == .inProgress ? pile.first : nil
    }

    public var clearedCount: Int { totalCards - pile.count }
    public var remaining: Int { pile.count }

    /// Fraction of the pile cleared, in [0, 1], for progress UI.
    public var progress: Double {
        guard totalCards > 0 else { return 1 }
        return Double(clearedCount) / Double(totalCards)
    }

    /// Records one graded answer for the current (front) card. Correct clears
    /// the card; wrong sends it to the back of the pile. Returns a `TimeCredit`
    /// when this answer empties the pile, else nil.
    @discardableResult
    public mutating func submit(_ answer: GradedAnswer, at date: Date) -> TimeCredit? {
        guard status == .inProgress, !pile.isEmpty else { return nil }
        let current = pile.removeFirst()
        if !answer.isCorrect {
            missCount += 1
            pile.append(current)
            return nil
        }
        if pile.isEmpty {
            status = .completed
            return TimeCredit(grantedAt: date, minutes: policy.minutesGranted)
        }
        return nil
    }

    public mutating func abandon() {
        guard status == .inProgress else { return }
        status = .abandoned
    }
}

/// Rolling record of grants, used to enforce the per-day unlock cap and to
/// answer "is access currently unlocked?". Persisted in the App Group so the
/// DeviceActivity extension can consult it too.
public struct UnlockLedger: Codable, Equatable, Sendable {
    public private(set) var credits: [TimeCredit] = []

    public init() {}

    public mutating func record(_ credit: TimeCredit) {
        credits.append(credit)
    }

    /// The credit currently keeping apps unlocked, if any.
    public func activeCredit(at date: Date) -> TimeCredit? {
        credits.last { $0.grantedAt <= date && date < $0.expiresAt }
    }

    public func grantsToday(at date: Date, calendar: Calendar = .current) -> Int {
        credits.filter { calendar.isDate($0.grantedAt, inSameDayAs: date) }.count
    }

    public func canStartSession(policy: UnlockPolicy, at date: Date, calendar: Calendar = .current) -> Bool {
        guard let cap = policy.maxUnlocksPerDay else { return true }
        return grantsToday(at: date, calendar: calendar) < cap
    }

    /// Drops credits older than `days` to keep the persisted blob small.
    public mutating func prune(before date: Date, keepingDays days: Int = 7) {
        let cutoff = date.addingTimeInterval(-Double(days) * 86_400)
        credits.removeAll { $0.expiresAt < cutoff }
    }
}
