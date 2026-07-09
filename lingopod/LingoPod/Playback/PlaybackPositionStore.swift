// M2
// Periodic + lifecycle persistence of `Episode.playbackPosition`/
// `playbackCompleted` (M2 spec §4).
import Foundation
import LingoPodKit
import SwiftData
import os

@MainActor
final class PlaybackPositionStore {
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.lingopod.app", category: "Playback")
    private var periodicTask: Task<Void, Never>?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Starts a 5s-interval save loop while `state == .playing`. Cancels
    /// any existing loop first (defensive — `PlayerEngine.play()` is the
    /// only caller and always pairs with a prior `pause()`/`stopPeriodicSave()`,
    /// but a stray double-`play()` must not spawn two loops).
    func startPeriodicSave(engine: PlayerEngine) {
        periodicTask?.cancel()
        periodicTask = Task { [weak self, weak engine] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                guard let self, let engine else { break }
                self.saveNow(engine: engine)
            }
        }
    }

    func stopPeriodicSave() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    /// Immediate write, per §4.1's "on pause"/"on seek (paused)"/"on
    /// episode switch"/"on backgrounding" call sites, in addition to the
    /// periodic loop above.
    func saveNow(engine: PlayerEngine) {
        guard let id = engine.currentEpisodeID,
              // VERIFY(iOS26): `ModelContext.model(for:)` — spec text (M2
              // §4.2) writes this as `try?`; kept as specified defensively
              // in case the SwiftData API surface for this call is throwing
              // on the toolchain this ships against.
              let episode = try? modelContext.model(for: id) as? Episode else { return }
        episode.playbackPosition = engine.currentTime
        if PlaybackTimeMath.isPastCompletionThreshold(currentTime: engine.currentTime, duration: engine.duration) {
            // Once true, only `AVPlayerItemDidPlayToEndTime`'s reset-to-zero
            // path (or a future explicit "mark unplayed" action, out of
            // scope for M2) un-sets this (§4.2).
            episode.playbackCompleted = true
        }
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save playback position: \(String(describing: error), privacy: .public)")
        }
    }
}
