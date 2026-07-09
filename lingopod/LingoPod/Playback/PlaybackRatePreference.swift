// M2
// `UserDefaults`-backed persisted playback rate (M2 spec §1.6). The rate
// preference is global — independent of any specific episode — matching
// Apple Podcasts behavior and avoiding surprise speed changes per episode.
import Foundation
import LingoPodKit

@MainActor
final class PlaybackRatePreference {
    /// Re-exported for UI/`NowPlayingInfoManager` call sites so they don't
    /// need to import `LingoPodKit` just for this constant.
    static let allowedSteps: [Float] = PlaybackTimeMath.allowedRateSteps
    static let defaultRate: Float = 1.0
    private static let storageKey = "playbackRate"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Clamped to `PlaybackTimeMath.allowedRateRange` on both read and
    /// write, defensively, in case a stale/out-of-range value was ever
    /// written by a previous app version.
    var currentRate: Float {
        get {
            guard defaults.object(forKey: Self.storageKey) != nil else { return Self.defaultRate }
            let stored = defaults.float(forKey: Self.storageKey)
            return PlaybackTimeMath.clampedRate(stored)
        }
        set {
            defaults.set(PlaybackTimeMath.clampedRate(newValue), forKey: Self.storageKey)
        }
    }
}
