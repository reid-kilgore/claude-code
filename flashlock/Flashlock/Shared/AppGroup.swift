import FamilyControls
import FlashlockCore
import Foundation

/// App Group constants shared by the app and all three extensions.
enum AppGroup {
    /// UserDefaults suite name and container identifier. Must match the
    /// `com.apple.security.application-groups` entitlement of every target.
    static let suiteName = "group.com.flashlock.shared"

    /// Keys in the shared defaults suite (docs/02-architecture.md §3).
    enum Key {
        static let selection = "selection"
        static let limitConfig = "limitConfig"
        static let unlockPolicy = "unlockPolicy"
        static let ledger = "ledger"
        static let dayState = "dayState"
        static let pendingGateRequest = "pendingGateRequest"
        static let onboardingComplete = "onboardingComplete"
    }
}

/// The user's daily screen-time limit configuration.
struct LimitConfig: Codable, Equatable {
    /// Cumulative minutes of use across the selected apps before shields go up.
    var dailyLimitMinutes: Int
    /// Master switch; when false Flashlock never shields anything.
    var isEnabled: Bool

    init(dailyLimitMinutes: Int = 60, isEnabled: Bool = false) {
        self.dailyLimitMinutes = dailyLimitMinutes
        self.isEnabled = isEnabled
    }
}

/// Per-day control-loop state. Every state is a timestamp — never a bare flag —
/// so any process can recompute "should the shield be up right now?"
/// idempotently even after missed callbacks (docs/02-architecture.md §2.4).
struct DayState: Codable, Equatable {
    /// When today's usage threshold fired; nil until the limit is hit. Cleared
    /// by the monitor at the start of each day, and ignored by the reconciler
    /// when it dates from a previous day (missed `intervalDidStart`).
    var limitReachedAt: Date?
    /// Last time any process ran the reconciler; diagnostics only.
    var lastReconcile: Date?

    init(limitReachedAt: Date? = nil, lastReconcile: Date? = nil) {
        self.limitReachedAt = limitReachedAt
        self.lastReconcile = lastReconcile
    }
}

/// Written by the shield-action extension when the user taps
/// "Practice to unlock"; consumed (and cleared) by the app on next foreground.
struct PendingGateRequest: Codable, Equatable {
    var requestedAt: Date

    init(requestedAt: Date) {
        self.requestedAt = requestedAt
    }
}

/// Typed Codable accessor over the shared UserDefaults suite.
///
/// Deliberately small: the monitor extension has a ~6 MB jetsam ceiling, so
/// this store must never grow deck/card data — those live in JSON files in the
/// App Group container and are loaded only by the main app.
struct SharedStore {
    private let defaults: UserDefaults

    /// NOTE: falls back to `.standard` when the suite can't be opened (e.g. a
    /// missing App Group entitlement) so extensions degrade instead of
    /// crashing; cross-process sharing will not work in that state.
    init(defaults: UserDefaults? = UserDefaults(suiteName: AppGroup.suiteName)) {
        self.defaults = defaults ?? .standard
    }

    // MARK: - Typed accessors

    /// Opaque token selection from `FamilyActivityPicker`. Best-effort cache:
    /// iOS occasionally rotates tokens, so treat a non-matching selection as
    /// recoverable by re-prompting the user to pick apps again.
    var selection: FamilyActivitySelection? {
        get { decode(AppGroup.Key.selection) }
        nonmutating set { encode(newValue, forKey: AppGroup.Key.selection) }
    }

    var limitConfig: LimitConfig {
        get { decode(AppGroup.Key.limitConfig) ?? LimitConfig() }
        nonmutating set { encode(newValue, forKey: AppGroup.Key.limitConfig) }
    }

    var unlockPolicy: UnlockPolicy {
        get { decode(AppGroup.Key.unlockPolicy) ?? UnlockPolicy() }
        nonmutating set { encode(newValue, forKey: AppGroup.Key.unlockPolicy) }
    }

    var ledger: UnlockLedger {
        get { decode(AppGroup.Key.ledger) ?? UnlockLedger() }
        nonmutating set { encode(newValue, forKey: AppGroup.Key.ledger) }
    }

    var dayState: DayState {
        get { decode(AppGroup.Key.dayState) ?? DayState() }
        nonmutating set { encode(newValue, forKey: AppGroup.Key.dayState) }
    }

    var pendingGateRequest: PendingGateRequest? {
        get { decode(AppGroup.Key.pendingGateRequest) }
        nonmutating set { encode(newValue, forKey: AppGroup.Key.pendingGateRequest) }
    }

    var isOnboarded: Bool {
        get { defaults.bool(forKey: AppGroup.Key.onboardingComplete) }
        nonmutating set { defaults.set(newValue, forKey: AppGroup.Key.onboardingComplete) }
    }

    // MARK: - JSON plumbing

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
