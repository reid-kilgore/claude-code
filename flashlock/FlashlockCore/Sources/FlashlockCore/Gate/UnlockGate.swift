import Foundation

/// User-configurable rule for how flashcards convert into screen time.
public struct UnlockPolicy: Codable, Equatable, Sendable {
    /// Correct answers required to earn one grant.
    public var requiredCorrect: Int
    /// Minutes of access earned per completed session.
    public var minutesGranted: Int
    /// Each wrong answer adds this many extra required cards (anti-spam:
    /// guessing through multiple choice has negative expected value).
    public var wrongAnswerPenalty: Int
    /// Cap on `requiredCorrect + penalties` so a bad run stays finishable.
    public var maxRequiredCorrect: Int
    /// Grants allowed per calendar day; nil = unlimited.
    public var maxUnlocksPerDay: Int?

    public init(
        requiredCorrect: Int = 5,
        minutesGranted: Int = 15,
        wrongAnswerPenalty: Int = 1,
        maxRequiredCorrect: Int = 12,
        maxUnlocksPerDay: Int? = nil
    ) {
        self.requiredCorrect = requiredCorrect
        self.minutesGranted = minutesGranted
        self.wrongAnswerPenalty = wrongAnswerPenalty
        self.maxRequiredCorrect = maxRequiredCorrect
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

/// State machine for one "answer cards to unlock" session.
///
/// Only objectively-graded answers (multiple choice / typed) feed this — the
/// quiz layer upgrades self-graded cards to multiple choice when
/// `forceRecall` is set, so "Good"-mashing can never mint screen time.
public struct GateSession: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case inProgress
        case completed
        case abandoned
    }

    public private(set) var policy: UnlockPolicy
    public private(set) var startedAt: Date
    public private(set) var correctCount: Int = 0
    public private(set) var wrongCount: Int = 0
    public private(set) var status: Status = .inProgress

    public init(policy: UnlockPolicy, startedAt: Date) {
        self.policy = policy
        self.startedAt = startedAt
    }

    /// Total correct answers currently required, including accrued penalties.
    public var requiredCorrect: Int {
        min(
            policy.requiredCorrect + wrongCount * policy.wrongAnswerPenalty,
            policy.maxRequiredCorrect
        )
    }

    public var remaining: Int {
        max(requiredCorrect - correctCount, 0)
    }

    /// Fraction complete in [0, 1], for progress UI.
    public var progress: Double {
        guard requiredCorrect > 0 else { return 1 }
        return min(Double(correctCount) / Double(requiredCorrect), 1)
    }

    /// Records one graded answer. Returns a `TimeCredit` when this answer
    /// completes the session, else nil.
    @discardableResult
    public mutating func submit(_ answer: GradedAnswer, at date: Date) -> TimeCredit? {
        guard status == .inProgress else { return nil }
        if answer.isCorrect {
            correctCount += 1
        } else {
            wrongCount += 1
        }
        if correctCount >= requiredCorrect {
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
