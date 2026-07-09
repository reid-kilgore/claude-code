// M2
// Test double for `AVPlayerWrapping` (M2 spec §9.1) — drives `PlayerEngine`
// deterministically without touching real media files or simulator audio
// hardware. `currentItem` is always `nil`: it deliberately doesn't attempt
// to fabricate a real `AVPlayerItem` with a controllable `.status`/
// `.duration`, so tests built on this double exercise the state-machine,
// rate, seek-clamping, auto-download, and notification behavior, not the
// AVPlayerItem-KVO-dependent paths (duration discovery, `.failed` status,
// buffering) — those are framework-touching and covered by the manual
// verification script (M2 spec §9.2) instead.
@testable import LingoPod
import AVFoundation
import Foundation

@MainActor
final class MockAVPlayerWrapping: AVPlayerWrapping {
    var rate: Float = 0
    var currentItem: AVPlayerItem? { nil }

    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var seekCalls: [(time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime)] = []
    /// Controls what the next `seek` completion resolves to — set `false`
    /// to simulate AVPlayer canceling a superseded seek.
    var seekResult = true

    func play() { playCallCount += 1 }
    func pause() { pauseCallCount += 1 }

    func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool {
        seekCalls.append((time, toleranceBefore, toleranceAfter))
        return seekResult
    }

    func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using: @escaping (CMTime) -> Void) -> Any {
        NSObject()
    }

    func removeTimeObserver(_ observer: Any) {}
}
