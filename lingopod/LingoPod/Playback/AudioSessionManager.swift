// M2
// `AVAudioSession` category/activation/interruption/route-change handling
// (M2 spec §2). Does not import/depend on `PlayerEngine` (avoids a circular
// dependency) — instead exposes closures that `PlayerEngine` wires at
// construction time.
import AVFoundation
import Foundation
import os

@MainActor
final class AudioSessionManager {
    private let logger = Logger(subsystem: "com.lingopod.app", category: "Playback")

    private var isCategoryConfigured = false
    private var interruptionToken: NSObjectProtocol?
    private var routeChangeToken: NSObjectProtocol?

    /// Fired on `.began`. `PlayerEngine` wires this to its own `pause()`
    /// (no-op if not currently playing, per M2 spec §2).
    var onInterruptionBegan: (() -> Void)?
    /// Fired on `.ended`, `shouldResume` reflects
    /// `AVAudioSessionInterruptionOptions.shouldResume`. `PlayerEngine`
    /// wires this to `play()` only when `shouldResume == true`.
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    /// Fired when the route changes for the "old device unavailable"
    /// reason (headphones/AirPods unplugged) — the only route-change reason
    /// M2 acts on (§2). `PlayerEngine` wires this to `pause()`.
    var onRouteChangeShouldPause: (() -> Void)?

    init() {
        // Observing starts immediately at construction (not deferred to
        // first playback) so an interruption beginning before any playback
        // doesn't go unnoticed — though there's nothing to pause yet in
        // that case (M2 spec §2).
        startObserving()
    }

    /// Configures the `.playback`/`.spokenAudio` category (idempotently)
    /// and activates the session. Called from `PlayerEngine.play()`, not at
    /// app launch (M0-scaffolding.md §7 / M2 spec §2).
    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            if !isCategoryConfigured {
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
                isCategoryConfigured = true
            }
            try session.setActive(true)
        } catch {
            logger.error("Failed to activate audio session: \(String(describing: error), privacy: .public)")
        }
    }

    /// Best-effort deactivation; failures are logged and swallowed (not
    /// worth surfacing to the user per architecture §8).
    func deactivate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("Failed to deactivate audio session (best-effort): \(String(describing: error), privacy: .public)")
        }
    }

    private func startObserving() {
        let center = NotificationCenter.default
        // `queue: .main` guarantees the block runs on the main
        // queue/thread, so `MainActor.assumeIsolated` below is sound even
        // though `NotificationCenter`'s block-based API itself is not
        // statically known to the compiler as MainActor-isolated.
        interruptionToken = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleInterruption(notification)
            }
        }
        routeChangeToken = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleRouteChange(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            onInterruptionBegan?()
        case .ended:
            var shouldResume = false
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            }
            onInterruptionEnded?(shouldResume)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        if reason == .oldDeviceUnavailable {
            onRouteChangeShouldPause?()
        }
    }

    deinit {
        // `NotificationCenter.removeObserver` is safe to call off the main
        // actor; `deinit` on a class is always `nonisolated`.
        if let interruptionToken {
            NotificationCenter.default.removeObserver(interruptionToken)
        }
        if let routeChangeToken {
            NotificationCenter.default.removeObserver(routeChangeToken)
        }
    }
}
