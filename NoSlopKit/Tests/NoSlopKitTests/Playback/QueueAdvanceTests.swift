import Testing
@testable import NoSlopKit

@Suite struct QueueAdvanceTests {
    private func action(
        _ request: QueueAdvance.Request?, queued: Int, isEnded: Bool, listIsOver: Bool = false
    ) -> QueueAdvance.Action {
        QueueAdvance.action(for: request, queued: queued, isEnded: isEnded, listIsOver: listIsOver)
    }

    // MARK: Nobody waited

    @Test func withoutARequestNothingHappensWhateverTheQueueAndTheVideoAre() {
        for queued in [0, 1, 40] {
            for isEnded in [false, true] {
                #expect(action(nil, queued: queued, isEnded: isEnded) == .nothing, "queued \(queued), ended \(isEnded)")
            }
        }
    }

    // MARK: The video ended and the queue was empty

    @Test func aPageThatBroughtVideosStartsTheNextOneAfterTheEnd() {
        #expect(action(.whenEnded, queued: 1, isEnded: true) == .startNext)
        #expect(action(.whenEnded, queued: 98, isEnded: true) == .startNext)
    }

    @Test func aViewerWhoReplayedOrSoughtMeanwhileIsNotInterrupted() {
        // The video is not over any more: replay, or a seek from the end, took it out of the ended state.
        #expect(action(.whenEnded, queued: 5, isEnded: false) == .nothing)
        #expect(action(.whenEnded, queued: 0, isEnded: false) == .nothing)
    }

    @Test func aPageThatBroughtNothingLeavesItToAutoplay() {
        // The list is over (or could not be reached): the queue is finished like any other.
        #expect(action(.whenEnded, queued: 0, isEnded: true) == .autoplay)
    }

    // MARK: The viewer asked for the next video

    @Test func nextStartsTheFirstQueuedVideoWhateverTheVideoIsDoing() {
        // The lock screen's Next while the video plays, or has ended meanwhile.
        #expect(action(.now, queued: 3, isEnded: false) == .startNext)
        #expect(action(.now, queued: 3, isEnded: true) == .startNext)
    }

    @Test func nextWithNothingBehindItLeavesThePlayingVideoAlone() {
        #expect(action(.now, queued: 0, isEnded: false) == .nothing)
    }

    @Test func nextWithNothingBehindItAfterTheVideoEndedLeavesItToAutoplay() {
        #expect(action(.now, queued: 0, isEnded: true) == .autoplay)
    }

    @Test func nextAtTheEndOfTheListFallsThroughToTheSuggestionWhateverTheVideoIsDoing() {
        #expect(action(.now, queued: 0, isEnded: false, listIsOver: true) == .suggestion)
        #expect(action(.now, queued: 0, isEnded: true, listIsOver: true) == .suggestion)
    }

    @Test func nextWhenThePageFailedKeepsThePlaylist() {
        // The list goes on (hasMore): a failed or empty page is no reason to leave it.
        #expect(action(.now, queued: 0, isEnded: false, listIsOver: false) == .nothing)
        #expect(action(.now, queued: 0, isEnded: true, listIsOver: false) == .autoplay)
    }

    @Test func aPageThatBroughtVideosStartsThemEvenWhenTheListIsOver() {
        #expect(action(.now, queued: 2, isEnded: false, listIsOver: true) == .startNext)
    }

    @Test func theEndOfTheListStaysWithAutoplayWhenTheVideoEnded() {
        // Autoplay still governs the natural end of a queue.
        #expect(action(.whenEnded, queued: 0, isEnded: true, listIsOver: true) == .autoplay)
        #expect(action(.whenEnded, queued: 0, isEnded: false, listIsOver: true) == .nothing)
    }
}
