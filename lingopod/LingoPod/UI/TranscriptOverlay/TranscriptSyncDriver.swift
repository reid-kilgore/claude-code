// M4
// Isolates the 4 Hz `currentTime` churn from everything that renders the
// transcript (docs/specs/M4-overlay-ui.md §4.2). `currentTime` changes on
// every playhead tick; `currentIndex` only changes when the computed
// "current segment" actually differs, so views reading `currentIndex`
// re-render far less often than 4 Hz.
import Foundation
import LingoPodKit
import os

@MainActor
@Observable
final class TranscriptSyncDriver {
    /// Only property other code should read. `nil` means "no segment is
    /// current yet" (before the first segment's startTime).
    private(set) var currentIndex: Int?

    private let logger = Logger(subsystem: "com.lingopod.app", category: "Overlay")

    /// Recomputes `currentIndex` via `SegmentSync.currentIndex` and updates
    /// the published property only if the result actually changed.
    func update(time: TimeInterval, startTimes: [TimeInterval]) {
        let newIndex = SegmentSync.currentIndex(in: startTimes, at: time)
        if newIndex != currentIndex {
            currentIndex = newIndex
        }
    }

    /// Directly assigns `currentIndex`, bypassing the `update(time:)`
    /// binary-search path. Used by tap-to-seek (§5): the tapped row must
    /// highlight as current immediately, without waiting for the next
    /// `currentTime` tick to catch up with the just-issued seek.
    func forceIndex(_ index: Int) {
        currentIndex = index
    }
}
