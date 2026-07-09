import DeviceActivity
import Foundation

/// Headless reactor for schedule/threshold events (docs/02-architecture.md §2).
///
/// Runs under a ~6 MB jetsam ceiling, so it touches only the shared settings
/// blob and ledger — never deck/card data. Every callback funnels through the
/// idempotent reconciler; nothing in here blindly toggles shields.
final class DeviceActivityMonitorExtension: DeviceActivityMonitor {

    /// New daily interval: reset day state so yesterday's limit no longer
    /// shields, then reconcile (which clears the shields).
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        let now = Date()
        let store = SharedStore()
        if activity == FlashlockActivity.daily {
            var day = store.dayState
            day.limitReachedAt = nil
            store.dayState = day
        }
        ShieldStateReconciler.reconcile(now: now, store: store)
    }

    /// End of the daily window or of a re-lock schedule. Ledger-guarded, never
    /// a blind re-shield: re-calling `startMonitoring` can fire this for a
    /// stale/replaced activity, and the user may have earned a newer credit
    /// mid-window — the reconciler checks `ledger.activeCredit(at:)` before
    /// putting shields back up.
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        let now = Date()
        let store = SharedStore()
        ShieldStateReconciler.reconcile(now: now, store: store)

        // Re-lock schedules are clamped to a short horizon; if the credit is
        // still active when the schedule ends, chain the next segment.
        if activity == FlashlockActivity.relock,
           let credit = store.ledger.activeCredit(at: now),
           let selection = store.selection {
            try? RelockScheduler.scheduleRelock(for: credit, selection: selection, now: now)
        }
    }

    /// Daily limit reached, or an earned-time usage grant consumed.
    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name, activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)
        let now = Date()
        let store = SharedStore()

        if event == FlashlockActivity.dailyLimitEvent {
            // Sanity check against spurious/early threshold fires (iOS 26.x
            // reports): the limit cannot plausibly be reached sooner than
            // `dailyLimitMinutes` of wall clock after the interval started at
            // midnight. Allow 1 minute of slack for hour-rounding quirks.
            let config = store.limitConfig
            let minutesSinceMidnight =
                now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 60
            if config.isEnabled,
               minutesSinceMidnight + 1 >= Double(config.dailyLimitMinutes) {
                var day = store.dayState
                if day.limitReachedAt == nil {
                    day.limitReachedAt = now
                    store.dayState = day
                }
            }
        }
        // For relockUsageEvent no state write is needed: the usage threshold
        // can only fire at/after the credit's wall-clock expiry, so the
        // reconciler already computes "shields up" from the ledger.
        ShieldStateReconciler.reconcile(now: now, store: store)
    }
}
