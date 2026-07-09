import DeviceActivity
import FamilyControls
import FlashlockCore
import Foundation
import ManagedSettings

/// Names for the two DeviceActivity registrations Flashlock uses. Shared by
/// the app (which registers them) and the monitor (which matches callbacks).
enum FlashlockActivity {
    /// Repeating 00:00–23:59 schedule carrying the daily-limit usage event.
    static let daily = DeviceActivityName("flashlockDaily")
    /// Non-repeating schedule that ends when an earned TimeCredit expires.
    static let relock = DeviceActivityName("flashlockRelock")

    /// Usage threshold event on `daily`: fires when the selected apps hit the
    /// user's daily limit.
    static let dailyLimitEvent = DeviceActivityEvent.Name("dailyLimit")
    /// Usage threshold event on `relock`, used for grants shorter than the
    /// 15-minute minimum schedule interval.
    static let relockUsageEvent = DeviceActivityEvent.Name("relockUsage")
}

/// Registers/stops the non-repeating re-lock schedule for an earned
/// `TimeCredit`. The monitor's `intervalDidEnd`/`eventDidReachThreshold` for
/// this activity re-applies shields via the ledger-guarded reconciler.
enum RelockScheduler {
    /// Undocumented de-facto minimum DeviceActivity interval, in minutes;
    /// shorter schedules make `startMonitoring` throw ("tightly scheduled").
    static let minimumIntervalMinutes = 15
    /// Schedules registered far out are reported unreliable, so re-lock
    /// schedules stay short-horizon; longer grants are chained by the monitor.
    static let maximumHorizonMinutes = 45

    /// Registers the re-lock for `credit`. Always stops any existing relock
    /// activity first (iOS 18: re-`startMonitoring` without `stopMonitoring`
    /// does not reliably re-arm callbacks).
    static func scheduleRelock(
        for credit: TimeCredit,
        selection: FamilyActivitySelection,
        now: Date = Date()
    ) throws {
        let center = DeviceActivityCenter()
        center.stopMonitoring([FlashlockActivity.relock])

        let remaining = credit.expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return }

        // Clamp the schedule to [minimum + buffer, maximum horizon]. If the
        // credit outlives the horizon, the monitor re-chains in intervalDidEnd.
        let minimumLength = TimeInterval(minimumIntervalMinutes) * 60 + 60
        let horizon = min(remaining + 60, TimeInterval(maximumHorizonMinutes) * 60)
        let intervalEnd = now.addingTimeInterval(max(horizon, minimumLength))

        // NOTE: full calendar components for a one-shot schedule; a
        // practitioner report claims hour/minute/second-only components are
        // the most reliable form, but those cannot represent an interval that
        // crosses midnight.
        let components: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
        let calendar = Calendar.current
        let schedule = DeviceActivitySchedule(
            intervalStart: calendar.dateComponents(components, from: now),
            intervalEnd: calendar.dateComponents(components, from: intervalEnd),
            repeats: false
        )

        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        if remaining < TimeInterval(minimumIntervalMinutes) * 60 {
            // Grants shorter than the minimum schedule interval re-lock via a
            // usage threshold instead: N minutes of usage takes at least N
            // minutes of wall clock, so the event can only fire at or after
            // the credit's wall-clock expiry — reconcile then re-shields. If
            // the user never opens the apps, the schedule's intervalDidEnd
            // (or the next app foreground) reconciles instead.
            let minutes = max(Int(remaining / 60), 1)
            events[FlashlockActivity.relockUsageEvent] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: [],
                webDomains: [],
                threshold: DateComponents(minute: minutes),
                includesPastActivity: false
            )
        }

        try center.startMonitoring(FlashlockActivity.relock, during: schedule, events: events)
    }

    static func cancelRelock() {
        DeviceActivityCenter().stopMonitoring([FlashlockActivity.relock])
    }
}

/// Registers/stops the repeating daily-limit schedule. Called from onboarding
/// and whenever the user edits the limit or the app selection.
enum DailyLimitScheduler {
    static func schedule(selection: FamilyActivitySelection, config: LimitConfig) throws {
        let center = DeviceActivityCenter()
        center.stopMonitoring([FlashlockActivity.daily])
        guard config.isEnabled, !selection.applicationTokens.isEmpty else { return }

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        // includesPastActivity: true (iOS 17.4+) so usage accrued before a
        // mid-day re-registration still counts toward today's limit.
        let event = DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: [],
            webDomains: [],
            threshold: DateComponents(minute: config.dailyLimitMinutes),
            includesPastActivity: true
        )
        try center.startMonitoring(
            FlashlockActivity.daily,
            during: schedule,
            events: [FlashlockActivity.dailyLimitEvent: event]
        )
    }

    static func cancel() {
        DeviceActivityCenter().stopMonitoring([FlashlockActivity.daily])
    }
}
