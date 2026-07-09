// M2
// Pure time/rate math extracted from `PlayerEngine` (LingoPod/Playback/) so
// it is covered by `swift test` without booting a simulator or touching
// AVFoundation/SwiftData (architecture §1, "unit-testable logic ... lives
// in ... LingoPodKit"; architecture §9). Everything here is a stateless,
// platform-agnostic function of plain values — no AVFoundation/SwiftData
// imports, matching the LingoPodKit contract.
import Foundation

public enum PlaybackTimeMath {
    /// M2 spec §1.6: `rate` is clamped to this range regardless of source
    /// (UI menu, `MPChangePlaybackRateCommandEvent`, direct assignment).
    public static let allowedRateRange: ClosedRange<Float> = 0.5...2.0

    /// The seven steps exposed in the UI rate menu / advertised to
    /// `MPRemoteCommandCenter.changePlaybackRateCommand.supportedPlaybackRates`
    /// (M2 spec §1.6/§5.2/§8.3). The engine itself accepts any `Float` in
    /// `allowedRateRange`; only the UI/remote-command surface is limited to
    /// these steps.
    public static let allowedRateSteps: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// M2 spec §4.2: `playbackCompleted` flips once played-fraction exceeds
    /// this threshold.
    public static let completionThreshold: Double = 0.95

    /// M2 spec §1.3 step 6: guard against "resuming" a stored position
    /// that's already within this many seconds of the end (the "small
    /// epsilon" the spec calls for but doesn't pin a literal value for).
    public static let resumeEpsilon: TimeInterval = 0.5

    /// Clamps a user/remote-command-requested rate to the supported range
    /// (M2 spec §1.6).
    public static func clampedRate(_ rate: Float) -> Float {
        min(max(rate, allowedRateRange.lowerBound), allowedRateRange.upperBound)
    }

    /// Clamps a seek target to `0...duration` (M2 spec §1.5). When
    /// `duration` is unknown yet, only the lower bound is enforced (matches
    /// the spec's `max(0, min(time, duration ?? time))`).
    public static func clampedSeekTarget(_ requested: TimeInterval, duration: TimeInterval?) -> TimeInterval {
        let lowerBounded = max(0, requested)
        guard let duration else { return lowerBounded }
        return min(lowerBounded, duration)
    }

    /// Whether `currentTime`/`duration` cross the "mark completed"
    /// threshold (M2 spec §4.2, >95%). `false` whenever `duration` is
    /// unknown or non-positive.
    public static func isPastCompletionThreshold(currentTime: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let duration, duration > 0 else { return false }
        return currentTime / duration > completionThreshold
    }

    /// Decides whether `load(episode:autoplay:)` should seek to a stored
    /// resume position before starting playback (M2 spec §1.3 step 6 /
    /// §4.3). Returns `nil` when playback should start from zero (nothing
    /// meaningful stored, already completed, or the stored position is
    /// already effectively at the end).
    public static func resumeTarget(storedPosition: TimeInterval, duration: TimeInterval?, playbackCompleted: Bool) -> TimeInterval? {
        guard !playbackCompleted, storedPosition > 0 else { return nil }
        if let duration, storedPosition >= duration - resumeEpsilon {
            return nil
        }
        return storedPosition
    }
}
