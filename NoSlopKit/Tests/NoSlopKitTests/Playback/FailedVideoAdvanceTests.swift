import Testing
@testable import NoSlopKit

@Suite struct FailedVideoAdvanceTests {
    private func action(
        isWorthRetrying: Bool = false,
        reachedByAdvance: Bool = true,
        hasNext: Bool = true,
        skippedInARow: Int = 0
    ) -> FailedVideoAdvance.Action {
        FailedVideoAdvance.action(
            isWorthRetrying: isWorthRetrying, reachedByAdvance: reachedByAdvance, hasNext: hasNext,
            skippedInARow: skippedInARow
        )
    }

    @Test func aPermanentFailureOfAVideoTheQueueStartedSkipsToTheNext() {
        #expect(action() == .skipToNext)
        #expect(action(skippedInARow: 2) == .skipToNext)
    }

    @Test func aFailureThatRetryCouldChangeStays() {
        #expect(action(isWorthRetrying: true) == .stay)
    }

    @Test func aVideoTheViewerOpenedStays() {
        #expect(action(reachedByAdvance: false) == .stay)
    }

    @Test func withoutANextVideoItStays() {
        #expect(action(hasNext: false) == .stay)
    }

    @Test func afterTheCapOfSkipsInARowItStays() {
        #expect(FailedVideoAdvance.maxSkipsInARow == 3)
        #expect(action(skippedInARow: 3) == .stay)
        #expect(action(skippedInARow: 10) == .stay)
    }

    @Test func theSkipWaitsAboutTwoSeconds() {
        #expect(FailedVideoAdvance.delay == .seconds(2))
    }
}
