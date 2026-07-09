// M2
import Testing
@testable import LingoPodKit

@Test func clampedRateWithinRangeIsUnchanged() {
    #expect(PlaybackTimeMath.clampedRate(1.25) == 1.25)
}

@Test func clampedRateBelowRangeClampsToLowerBound() {
    #expect(PlaybackTimeMath.clampedRate(0.1) == 0.5)
}

@Test func clampedRateAboveRangeClampsToUpperBound() {
    #expect(PlaybackTimeMath.clampedRate(9) == 2.0)
}

@Test func allowedRateStepsMatchesSpecExactly() {
    #expect(PlaybackTimeMath.allowedRateSteps == [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
}

@Test func clampedSeekTargetNeverNegative() {
    #expect(PlaybackTimeMath.clampedSeekTarget(-10, duration: 100) == 0)
}

@Test func clampedSeekTargetClampsToKnownDuration() {
    #expect(PlaybackTimeMath.clampedSeekTarget(500, duration: 100) == 100)
}

@Test func clampedSeekTargetWithUnknownDurationOnlyEnforcesLowerBound() {
    #expect(PlaybackTimeMath.clampedSeekTarget(500, duration: nil) == 500)
}

@Test func completionThresholdNotCrossedBelow95Percent() {
    #expect(PlaybackTimeMath.isPastCompletionThreshold(currentTime: 94, duration: 100) == false)
}

@Test func completionThresholdCrossedAbove95Percent() {
    #expect(PlaybackTimeMath.isPastCompletionThreshold(currentTime: 96, duration: 100) == true)
}

@Test func completionThresholdFalseWhenDurationUnknown() {
    #expect(PlaybackTimeMath.isPastCompletionThreshold(currentTime: 96, duration: nil) == false)
}

@Test func completionThresholdFalseWhenDurationZero() {
    #expect(PlaybackTimeMath.isPastCompletionThreshold(currentTime: 0, duration: 0) == false)
}

@Test func resumeTargetNilWhenNothingStored() {
    #expect(PlaybackTimeMath.resumeTarget(storedPosition: 0, duration: 100, playbackCompleted: false) == nil)
}

@Test func resumeTargetNilWhenAlreadyCompleted() {
    #expect(PlaybackTimeMath.resumeTarget(storedPosition: 50, duration: 100, playbackCompleted: true) == nil)
}

@Test func resumeTargetNilWhenStoredPositionNearEnd() {
    #expect(PlaybackTimeMath.resumeTarget(storedPosition: 99.9, duration: 100, playbackCompleted: false) == nil)
}

@Test func resumeTargetReturnsStoredPositionWhenValid() {
    #expect(PlaybackTimeMath.resumeTarget(storedPosition: 42, duration: 100, playbackCompleted: false) == 42)
}

@Test func resumeTargetReturnsStoredPositionWhenDurationUnknown() {
    #expect(PlaybackTimeMath.resumeTarget(storedPosition: 42, duration: nil, playbackCompleted: false) == 42)
}
