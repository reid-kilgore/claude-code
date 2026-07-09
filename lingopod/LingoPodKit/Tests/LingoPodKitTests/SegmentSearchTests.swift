// M3
// Covers SegmentSync.currentIndex, the binary-search "which segment is
// current" utility M4's TranscriptSyncDriver depends on
// (docs/specs/M4-overlay-ui.md §4.1).
import Testing
import Foundation
@testable import LingoPodKit

@Suite("SegmentSync")
struct SegmentSearchTests {
    @Test func emptyArrayReturnsNil() {
        #expect(SegmentSync.currentIndex(in: [], at: 5.0) == nil)
    }

    @Test func timeBeforeFirstStartReturnsNil() {
        let starts: [TimeInterval] = [1.0, 3.0, 6.0]
        #expect(SegmentSync.currentIndex(in: starts, at: 0.5) == nil)
    }

    @Test func timeExactlyEqualToAStartTimeReturnsThatIndex() {
        let starts: [TimeInterval] = [0.0, 1.0, 3.0, 6.0]
        #expect(SegmentSync.currentIndex(in: starts, at: 3.0) == 2)
        #expect(SegmentSync.currentIndex(in: starts, at: 0.0) == 0)
    }

    @Test func timeInAGapReturnsPreviousIndex() {
        // Segment 1 spans conceptually [1.0, 2.0), segment 2 starts at 6.0
        // -- a gap. At t=4.0 (inside the gap), segment 1 should still be
        // "current" (endTime is never consulted by this function).
        let starts: [TimeInterval] = [0.0, 1.0, 6.0]
        #expect(SegmentSync.currentIndex(in: starts, at: 4.0) == 1)
    }

    @Test func timePastLastSegmentReturnsLastIndex() {
        let starts: [TimeInterval] = [0.0, 1.0, 3.0]
        #expect(SegmentSync.currentIndex(in: starts, at: 1000.0) == 2)
    }

    @Test func singleSegmentArrayAtVariousTimes() {
        let starts: [TimeInterval] = [5.0]
        #expect(SegmentSync.currentIndex(in: starts, at: 0.0) == nil)
        #expect(SegmentSync.currentIndex(in: starts, at: 5.0) == 0)
        #expect(SegmentSync.currentIndex(in: starts, at: 500.0) == 0)
    }

    @Test func backwardSeekIsHandledStatelessly() {
        let starts: [TimeInterval] = [0.0, 2.0, 4.0, 8.0]
        #expect(SegmentSync.currentIndex(in: starts, at: 9.0) == 3)
        // Seek backward -- must not assume monotonic query times.
        #expect(SegmentSync.currentIndex(in: starts, at: 1.0) == 0)
        #expect(SegmentSync.currentIndex(in: starts, at: 5.0) == 2)
    }
}
