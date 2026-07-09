import FamilyControls
import Foundation
import ManagedSettings

/// Recomputes and re-asserts the correct shield state from App Group
/// timestamps. Idempotent by design: the DeviceActivity callbacks are flaky
/// (extensions sometimes never launch, thresholds fire late/batched), so this
/// runs on every app foreground, every monitor callback, and after every gate
/// completion — a missed unlock or re-lock is fixed at the next opportunity
/// (docs/02-architecture.md §2.4).
enum ShieldStateReconciler {
    /// The named store all Flashlock shields go through. Named stores are
    /// shared automatically between the app and its extensions.
    static let storeName = ManagedSettingsStore.Name("flashlock")

    /// Reads the shared store, decides whether shields should be up right now,
    /// and applies that decision. Returns the decision so callers can update UI.
    @discardableResult
    static func reconcile(now: Date = Date(), store: SharedStore = SharedStore()) -> Bool {
        let managed = ManagedSettingsStore(named: storeName)
        let config = store.limitConfig
        var dayState = store.dayState

        // A limitReachedAt from a previous calendar day means the daily
        // intervalDidStart callback was missed — treat the limit as not reached.
        if let reachedAt = dayState.limitReachedAt,
           !Calendar.current.isDate(reachedAt, inSameDayAs: now) {
            dayState.limitReachedAt = nil
        }

        let limitReached = dayState.limitReachedAt != nil
        let hasActiveCredit = store.ledger.activeCredit(at: now) != nil
        let shieldsShouldBeUp = config.isEnabled && limitReached && !hasActiveCredit

        if shieldsShouldBeUp, let selection = store.selection {
            // MVP shields explicit token snapshots only; category policies
            // (`.all(except:)`) are post-MVP (docs/02-architecture.md §6).
            let apps = selection.applicationTokens
            let domains = selection.webDomainTokens
            managed.shield.applications = apps.isEmpty ? nil : apps
            managed.shield.webDomains = domains.isEmpty ? nil : domains
        } else {
            // nil removes our configuration for the setting entirely.
            managed.shield.applications = nil
            managed.shield.webDomains = nil
        }

        dayState.lastReconcile = now
        store.dayState = dayState
        return shieldsShouldBeUp
    }
}
