import Foundation
import Testing
@testable import NoSlopKit

private func video(
    _ id: String,
    live: Bool = false,
    upcoming: Bool = false,
    short: Bool = false
) -> VideoSummary {
    VideoSummary(id: id, title: "Video \(id)", isLive: live, isUpcoming: upcoming, isShort: short)
}

private func ids(_ videos: [VideoSummary]) -> [String] {
    videos.map(\.id)
}

@Suite struct AutoplayPlannerTests {
    private let nothingWatched: (String) -> Double? = { _ in nil }

    // MARK: Choosing

    @Test func startsTheFirstSuggestionAndKeepsTheRestInOrder() {
        let upNext = [video("b"), video("c"), video("d")]
        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched)
        #expect(step?.next.id == "b")
        #expect(ids(step?.remaining ?? []) == ["c", "d"])
    }

    @Test func theVideoThatJustEndedIsNeverStartedAgain() {
        let upNext = [video("a"), video("b")]
        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched)
        #expect(step?.next.id == "b")
        #expect(step?.remaining.isEmpty == true)
    }

    @Test func watchedVideosAreSkippedAndDropped() {
        let progress: (String) -> Double? = { ["b": 300, "d": 45][$0] }
        let upNext = [video("b"), video("c"), video("d"), video("e")]
        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: progress)
        #expect(step?.next.id == "c")
        #expect(ids(step?.remaining ?? []) == ["e"])
    }

    @Test func tenSecondsOfProgressMakeAVideoWatchedAndNineDoNot() {
        #expect(AutoplayPlanner.watchedAfter == 10)
        let upNext = [video("b"), video("c")]

        let almost = AutoplayPlanner.step(after: "a", upNext: upNext, progress: { $0 == "b" ? 9.99 : nil })
        #expect(almost?.next.id == "b")

        let watched = AutoplayPlanner.step(after: "a", upNext: upNext, progress: { $0 == "b" ? 10 : nil })
        #expect(watched?.next.id == "c")
        #expect(watched?.remaining.isEmpty == true)
    }

    @Test func shortsLiveStreamsAndPremieresAreNotAutoplayed() {
        let upNext = [video("s", short: true), video("l", live: true), video("u", upcoming: true), video("ok")]
        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched)
        #expect(step?.next.id == "ok")
        // They would never be chosen, so they do not stay up next either.
        #expect(step?.remaining.isEmpty == true)
    }

    @Test func nothingToStartGivesNoStep() {
        #expect(AutoplayPlanner.step(after: "a", upNext: [], progress: nothingWatched) == nil)
        #expect(AutoplayPlanner.step(after: "a", upNext: [video("a")], progress: nothingWatched) == nil)
        #expect(AutoplayPlanner.step(after: "a", upNext: [video("b")], progress: { _ in 600 }) == nil)
        #expect(AutoplayPlanner.step(after: "a", upNext: [video("s", short: true)], progress: nothingWatched) == nil)
    }

    @Test func aRepeatedSuggestionIsStartedOnceAndLeavesNoCopy() {
        let upNext = [video("b"), video("c"), video("b"), video("d")]
        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched)
        #expect(step?.next.id == "b")
        #expect(ids(step?.remaining ?? []) == ["c", "d"])
    }

    @Test func noCurrentVideoStartsTheFirstSuggestion() {
        let step = AutoplayPlanner.step(after: nil, upNext: [video("a"), video("b")], progress: nothingWatched)
        #expect(step?.next.id == "a")
        #expect(ids(step?.remaining ?? []) == ["b"])
    }

    // MARK: Hopping on with the player minimized

    @Test func theRemainingListCarriesAutoplayThroughSeveralVideosWithoutAWatchPage() {
        // The watch page is not on screen, so nothing replaces the list between the videos.
        var watched: [String: Double] = ["a": 600]
        var upNext = [video("b"), video("c"), video("d")]
        var current = "a"
        var played: [String] = []

        while let step = AutoplayPlanner.step(after: current, upNext: upNext, progress: { watched[$0] }) {
            played.append(step.next.id)
            watched[step.next.id] = 600       // watched to the end
            current = step.next.id
            upNext = step.remaining
        }

        #expect(played == ["b", "c", "d"])
        #expect(upNext.isEmpty)
    }

    @Test func theNextVideosListReplacesWhatWasKept() {
        // What the watch page does once it has loaded the related videos of the video that started.
        var upNext = [video("c"), video("d")]
        let step = AutoplayPlanner.step(after: "a", upNext: [video("b")] + upNext, progress: nothingWatched)
        #expect(step?.next.id == "b")
        upNext = [video("x"), video("a")]

        // "a" was watched to the end, so it is not suggested again.
        let following = AutoplayPlanner.step(after: "b", upNext: upNext, progress: { $0 == "a" ? 600 : nil })
        #expect(following?.next.id == "x")
        #expect(following?.remaining.isEmpty == true)
    }
}
