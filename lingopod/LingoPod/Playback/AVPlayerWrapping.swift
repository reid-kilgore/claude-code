// M2
// Thin protocol wrapping only the `AVPlayer` surface `PlayerEngine` needs,
// so `MockAVPlayerWrapping` test doubles can drive the engine
// deterministically without touching real media files or simulator audio
// hardware (architecture §9; M2 spec §9.1).
import AVFoundation
import Foundation

@MainActor
protocol AVPlayerWrapping: AnyObject {
    var rate: Float { get set }
    var currentItem: AVPlayerItem? { get }
    func play()
    func pause()
    func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool
    func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using: @escaping (CMTime) -> Void) -> Any
    func removeTimeObserver(_ observer: Any)
}

/// `AVPlayer` already implements every member above (matching signatures)
/// except the async `seek`, which bridges AVFoundation's
/// completion-handler-based API. `// VERIFY(iOS26):` the exact actor
/// isolation story for extending a non-isolated Objective-C class with a
/// `@MainActor` protocol conformance is asserted here via the explicit
/// `@MainActor` on the new member; the inherited members (`rate`,
/// `currentItem`, `play()`, `pause()`, `addPeriodicTimeObserver`,
/// `removeTimeObserver`) are `nonisolated` on `AVPlayer` itself, which
/// trivially satisfies a `@MainActor` protocol requirement.
extension AVPlayer: AVPlayerWrapping {
    @MainActor
    func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool {
        await withCheckedContinuation { continuation in
            self.seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { finished in
                // A `false` (superseded by a newer seek) is not an error —
                // just resume so the continuation doesn't leak (M2 spec §1.5).
                continuation.resume(returning: finished)
            }
        }
    }
}
