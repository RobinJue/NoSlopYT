import Testing
@testable import NoSlopKit

@Suite struct PlaybackScanTests {
    @Test func theLeftHalfScansBackAndTheRightHalfForward() {
        #expect(PlaybackScan.direction(forTouchAt: 10, width: 400) == .backward)
        #expect(PlaybackScan.direction(forTouchAt: 199.9, width: 400) == .backward)
        #expect(PlaybackScan.direction(forTouchAt: 200, width: 400) == .forward)
        #expect(PlaybackScan.direction(forTouchAt: 390, width: 400) == .forward)
    }

    @Test func aBackwardScanGoesBackAtTwiceTheSpeed() {
        #expect(PlaybackScan.reverseTarget(from: 60, elapsed: 0) == 60)
        #expect(PlaybackScan.reverseTarget(from: 60, elapsed: 1) == 58)
        #expect(PlaybackScan.reverseTarget(from: 60, elapsed: 10) == 40)
    }

    @Test func aBackwardScanStopsAtTheStartOfTheVideo() {
        #expect(PlaybackScan.reverseTarget(from: 5, elapsed: 3) == 0)
        #expect(PlaybackScan.reverseTarget(from: 5, elapsed: 1_000) == 0)
        #expect(PlaybackScan.reverseTarget(from: 0, elapsed: 2) == 0)
    }

    @Test func timesThatAreNotNumbersAreHarmless() {
        #expect(PlaybackScan.reverseTarget(from: .nan, elapsed: 1) == 0)
        #expect(PlaybackScan.reverseTarget(from: .infinity, elapsed: 1) == 0)
        #expect(PlaybackScan.reverseTarget(from: 30, elapsed: .nan) == 30)
        #expect(PlaybackScan.reverseTarget(from: 30, elapsed: -5) == 30)
    }

    @Test func theHoldIsLongerThanATapAndShorterThanALongWait() {
        #expect(PlaybackScan.holdDelay > 0.2)
        #expect(PlaybackScan.holdDelay < 0.6)
        #expect(PlaybackScan.speed == 2)
    }
}
