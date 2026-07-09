// M3
// Binary-search "which segment is current" utility. Owned by M3 (this is
// pure time math alongside the rest of the transcript pipeline) but its
// name/signature/location are pinned by docs/specs/M4-overlay-ui.md §4.1
// since `TranscriptSyncDriver` (M4, LingoPod/UI/TranscriptOverlay/) calls
// it directly — implemented here so M4 has a working dependency from day
// one.
import Foundation

public enum SegmentSync {
    /// Binary search over ascending segment start times to find the segment
    /// that should be highlighted as "current" at a given playhead time.
    ///
    /// Semantics:
    /// - `startTimes` must be sorted ascending (segments are always ordered
    ///   by `startTime` in the data model — caller's responsibility).
    /// - Returns the index of the **last** segment whose `startTime <= time`.
    /// - Before the first segment (`time < startTimes[0]`), or if
    ///   `startTimes` is empty: returns `nil` (no current segment yet).
    /// - In a gap between segment i's endTime and segment i+1's startTime
    ///   (feed transcripts can have gaps): still returns `i` — the previous
    ///   segment stays highlighted until the next one actually starts. This
    ///   falls out naturally from "last startTime <= time"; `endTime` is
    ///   never consulted by this function.
    /// - At or after the last segment's startTime (including past its
    ///   endTime, i.e. past the end of the transcript): returns
    ///   `startTimes.count - 1`. The last line stays highlighted; it never
    ///   reverts to `nil`.
    ///
    /// Stateless, pure query — `time` can jump backward on seek; this
    /// function does not assume monotonicity.
    public static func currentIndex(in startTimes: [TimeInterval], at time: TimeInterval) -> Int? {
        guard !startTimes.isEmpty else { return nil }

        // Rightmost insertion point (upper bound: first index whose
        // startTime > time), minus one.
        var low = 0
        var high = startTimes.count
        while low < high {
            let mid = low + (high - low) / 2
            if startTimes[mid] <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let index = low - 1
        return index >= 0 ? index : nil
    }
}
