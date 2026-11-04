import Foundation
import Testing
@testable import NoSlopKit

// What the Next button starts (spec-7): the next queued video, or without a queue the first unwatched Up next video, as
// autoplay would. The lock screen's Next asks the same question, so the two cannot disagree.

private func video(_ id: String, isShort: Bool = false, isLive: Bool = false) -> VideoSummary {
    VideoSummary(id: id, title: "Video \(id)", isLive: isLive, isShort: isShort)
}

@Suite struct NextVideoTests {
    private let step = AutoplayPlanner.Step(next: video("s1"), remaining: [video("s2"), video("s3")])

    @Test func aQueuedVideoComesFirst() {
        // Also when the list has pages to come and when Up next has a suggestion.
        #expect(NextVideo.choose(queued: 3, listHasMore: false, suggestion: nil) == .queued)
        #expect(NextVideo.choose(queued: 1, listHasMore: true, suggestion: step) == .queued)
    }

    @Test func withNothingQueuedTheNextPageOfTheListComesBeforeASuggestion() {
        #expect(NextVideo.choose(queued: 0, listHasMore: true, suggestion: nil) == .nextPage)
        #expect(NextVideo.choose(queued: 0, listHasMore: true, suggestion: step) == .nextPage)
    }

    @Test func withoutAQueueTheFirstUpNextSuggestionIsStarted() {
        #expect(NextVideo.choose(queued: 0, listHasMore: false, suggestion: step) == .suggested(step))
    }

    @Test func thereCanBeNothingNext() {
        let nothing = NextVideo.choose(queued: 0, listHasMore: false, suggestion: nil)

        #expect(nothing == .nothing)
        #expect(!nothing.isAvailable)
    }

    @Test func everythingElseIsAvailable() {
        #expect(NextVideo.queued.isAvailable)
        #expect(NextVideo.nextPage.isAvailable)
        #expect(NextVideo.suggested(step).isAvailable)
    }

    @Test func theSuggestionIsOnlyWorkedOutWhenNothingIsQueued() {
        // The controls ask this on every redraw: the Up next list is not walked while a queue has the answer.
        var asked = 0
        func suggestion() -> AutoplayPlanner.Step? {
            asked += 1
            return step
        }

        _ = NextVideo.choose(queued: 2, listHasMore: false, suggestion: suggestion())
        _ = NextVideo.choose(queued: 0, listHasMore: true, suggestion: suggestion())
        #expect(asked == 0)

        _ = NextVideo.choose(queued: 0, listHasMore: false, suggestion: suggestion())
        #expect(asked == 1)
    }

    @Test func theSuggestionIsTheVideoAutoplayWouldStart() {
        // The first suggestion that is unwatched and that autoplay may start: not the video itself, not a watched one,
        // not a Short or a live stream. The others stay up next behind it.
        let upNext = [
            video("current"), video("watched"), video("short", isShort: true), video("live", isLive: true),
            video("fresh"), video("later"),
        ]
        let suggestion = AutoplayPlanner.step(
            after: "current",
            upNext: upNext,
            progress: { $0 == "watched" ? 60 : nil }
        )

        let choice = NextVideo.choose(queued: 0, listHasMore: false, suggestion: suggestion)

        #expect(choice == .suggested(AutoplayPlanner.Step(next: video("fresh"), remaining: [video("later")])))
    }

    @Test func anUpNextListWithNothingToStartLeavesNothingNext() {
        // Every suggestion is watched: Next has nothing to start, like autoplay.
        let upNext = [video("a"), video("b")]
        let suggestion = AutoplayPlanner.step(after: "current", upNext: upNext, progress: { _ in 120 })

        #expect(NextVideo.choose(queued: 0, listHasMore: false, suggestion: suggestion) == .nothing)
    }
}
