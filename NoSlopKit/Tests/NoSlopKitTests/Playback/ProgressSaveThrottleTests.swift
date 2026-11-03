import Foundation
import Testing
@testable import NoSlopKit

@Suite struct ProgressSaveThrottleTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// What the throttle answers for each (seconds after `t0`, forced) pair, in order. (`#expect` cannot call a
    /// mutating member itself, so the answers are collected first.)
    private func answers(_ calls: [(at: Double, force: Bool)]) -> [Bool] {
        var throttle = ProgressSaveThrottle()
        return calls.map { throttle.shouldSave(now: t0.addingTimeInterval($0.at), force: $0.force) }
    }

    private func answers(at offsets: [Double]) -> [Bool] {
        answers(offsets.map { (at: $0, force: false) })
    }

    @Test func theIntervalIsTenSeconds() {
        #expect(ProgressSaveThrottle.interval == 10)
    }

    @Test func theFirstCallSaves() {
        #expect(answers(at: [0]) == [true])
    }

    @Test func aPlayingVideoSavesEveryTenSecondsOnTheHalfSecondTicksOfThePlayer() {
        // The player's clock ticks every half second; forty seconds of playback.
        let offsets = (0...80).map { Double($0) * 0.5 }
        let saved = zip(offsets, answers(at: offsets)).filter(\.1).map(\.0)
        #expect(saved == [0, 10, 20, 30, 40])
    }

    @Test func justUnderTenSecondsIsTooSoonAndExactlyTenSecondsIsTime() {
        #expect(answers(at: [0, 9.99, 10]) == [true, false, true])
    }

    @Test func aRefusedCallDoesNotMoveTheInterval() {
        // Ten seconds after the save, not after the last refusal.
        #expect(answers(at: [0, 5, 9, 10, 15, 19.9, 20]) == [true, false, false, true, false, false, true])
    }

    @Test func aForcedSaveAlwaysSavesAndStartsANewInterval() {
        // Pause, close, background, the end and a video switch do not wait.
        let result = answers([
            (at: 0, force: false),
            (at: 4, force: true),
            (at: 13.9, force: false),
            (at: 14, force: false),
        ])
        #expect(result == [true, true, false, true])
    }

    @Test func forcedSavesInARowAllSave() {
        let result = answers([(at: 0, force: true), (at: 0, force: true), (at: 0.1, force: true)])
        #expect(result == [true, true, true])
    }

    @Test func aClockSetBackSavesAndTheIntervalRunsFromTheNewTime() {
        let offsets: [Double] = [0, -3_600, -3_591, -3_590]
        #expect(answers(at: offsets) == [true, true, false, true])
    }

    @Test func aTwoMinuteVideoIsSavedTwelveTimesNotTwentyFour() {
        let offsets = (0..<240).map { Double($0) * 0.5 }
        #expect(answers(at: offsets).filter { $0 }.count == 12)
    }
}
