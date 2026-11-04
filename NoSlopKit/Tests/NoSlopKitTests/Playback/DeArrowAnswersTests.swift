import Foundation
import Testing
@testable import NoSlopKit

// What the app may remember of DeArrow's answers (performance-3): a title and "there is none" are answers, a lookup
// that failed is not. Remembered as "none" it kept the clickbait title on screen until the app was killed.

/// A clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// An empty memory on the test's clock.
private func memory(
    capacity: Int = DeArrowAnswers.defaultCapacity,
    retryDelay: TimeInterval = 60,
    clock: ManualClock = ManualClock()
) -> DeArrowAnswers {
    DeArrowAnswers(capacity: capacity, retryDelay: retryDelay, now: { clock.now })
}

@Suite struct DeArrowAnswersTests {
    // MARK: What is remembered

    @Test func aVideoNobodyAskedAboutIsUnknown() {
        let answers = memory()
        #expect(answers.recall("v") == .unknown)
    }

    @Test func aTitleIsRemembered() {
        let clock = ManualClock()
        var answers = memory(clock: clock)
        answers.record(.title("Plain title"), for: "v")

        #expect(answers.recall("v") == .answer("Plain title"))
        clock.advance(by: 86_400)
        #expect(answers.recall("v") == .answer("Plain title"), "an answer does not expire")
        #expect(answers.recall("other") == .unknown)
    }

    @Test func noBetterTitleIsRememberedAsAnAnswerToo() {
        var answers = memory()
        answers.record(.none, for: "v")

        #expect(answers.recall("v") == .answer(nil))
    }

    @Test func aFailureIsNotRememberedAsAnAnswer() {
        var answers = memory()
        answers.record(.failed, for: "v")

        // The old cache stored nil here, "looked up, there is none", and the card kept its original title for good.
        #expect(answers.recall("v") != .answer(nil))
        #expect(answers.recall("v") == .waiting)
    }

    // MARK: The wait after a failure

    @Test func aFailedVideoIsLeftAloneForTheRetryDelayAndAskedAboutAfterwards() {
        let clock = ManualClock()
        var answers = memory(retryDelay: 60, clock: clock)
        answers.record(.failed, for: "v")

        clock.advance(by: 59)
        #expect(answers.recall("v") == .waiting)
        clock.advance(by: 1)
        #expect(answers.recall("v") == .unknown, "after 60 s the next appearance asks again")
        clock.advance(by: 3_600)
        #expect(answers.recall("v") == .unknown)
    }

    @Test func theDefaultWaitIsAboutAMinute() {
        #expect(DeArrowAnswers.defaultRetryDelay == 60)
        #expect(DeArrowAnswers().retryDelay == 60)
    }

    @Test func eachVideoWaitsOnItsOwn() {
        let clock = ManualClock()
        var answers = memory(retryDelay: 60, clock: clock)
        answers.record(.failed, for: "early")
        clock.advance(by: 40)
        answers.record(.failed, for: "late")
        clock.advance(by: 30)

        #expect(answers.recall("early") == .unknown, "70 s ago")
        #expect(answers.recall("late") == .waiting, "30 s ago")
    }

    @Test func aSecondFailureStartsTheWaitOver() {
        let clock = ManualClock()
        var answers = memory(retryDelay: 60, clock: clock)
        answers.record(.failed, for: "v")
        clock.advance(by: 61)
        #expect(answers.recall("v") == .unknown)

        answers.record(.failed, for: "v")
        #expect(answers.recall("v") == .waiting)
    }

    @Test func anAnswerEndsTheWaitAndAFailureNeverTakesAnAnswerBack() {
        var answers = memory()
        answers.record(.failed, for: "v")
        answers.record(.title("Found"), for: "v")
        #expect(answers.recall("v") == .answer("Found"))

        // A lookup that was in flight when the answer came in, failing late.
        answers.record(.failed, for: "v")
        #expect(answers.recall("v") == .answer("Found"))
    }

    @Test func aClockThatWentBackwardsDoesNotLeaveAVideoWaitingForGood() {
        let clock = ManualClock()
        var answers = memory(retryDelay: 60, clock: clock)
        answers.record(.failed, for: "v")
        clock.advance(by: -3_600)

        #expect(answers.recall("v") == .unknown)
    }

    @Test func forgettingFailuresEndsEveryWaitAndKeepsTheAnswers() {
        var answers = memory()
        answers.record(.title("Found"), for: "titled")
        answers.record(.none, for: "plain")
        answers.record(.failed, for: "down")
        answers.record(.failed, for: "also down")

        let hadFailures = answers.forgetFailures()
        #expect(hadFailures, "there were failures to forget")
        #expect(answers.recall("down") == .unknown)
        #expect(answers.recall("also down") == .unknown)
        #expect(answers.recall("titled") == .answer("Found"))
        #expect(answers.recall("plain") == .answer(nil))
        let hadMore = answers.forgetFailures()
        #expect(!hadMore, "nothing left to forget")
    }

    // MARK: Newer answers

    @Test func aNewerAnswerReplacesAnOlderOne() {
        var answers = memory()
        answers.record(.none, for: "v")
        answers.record(.title("Now there is one"), for: "v")
        #expect(answers.recall("v") == .answer("Now there is one"))

        answers.record(.none, for: "v")
        #expect(answers.recall("v") == .answer(nil))
    }

    // MARK: Size

    @Test func theOldestAnswersGoWhenTheMemoryIsFull() {
        var answers = memory(capacity: 3)
        for id in ["a", "b", "c", "d"] {
            answers.record(.title("Title \(id)"), for: id)
        }

        #expect(answers.recall("a") == .unknown, "the oldest went")
        #expect(answers.recall("b") == .answer("Title b"))
        #expect(answers.recall("c") == .answer("Title c"))
        #expect(answers.recall("d") == .answer("Title d"))
    }

    @Test func recordingAnAnswerAgainMakesItTheNewest() {
        var answers = memory(capacity: 2)
        answers.record(.title("A"), for: "a")
        answers.record(.title("B"), for: "b")
        answers.record(.title("A again"), for: "a")
        answers.record(.title("C"), for: "c")

        #expect(answers.recall("b") == .unknown, "b is the oldest now")
        #expect(answers.recall("a") == .answer("A again"))
        #expect(answers.recall("c") == .answer("C"))
    }

    @Test func manyFailuresDoNotGrowWithoutBound() {
        let clock = ManualClock()
        var answers = memory(capacity: 5, retryDelay: 60, clock: clock)
        for number in 0..<20 {
            answers.record(.failed, for: "v\(number)")
            clock.advance(by: 1)
        }

        // Only the latest few are still waiting, the rest were let go (which just means they are asked about again).
        let waiting = (0..<20).filter { answers.recall("v\($0)") == .waiting }
        #expect(waiting.count <= 5)
        #expect(waiting.contains(19), "the newest failure is still waiting")
    }
}
