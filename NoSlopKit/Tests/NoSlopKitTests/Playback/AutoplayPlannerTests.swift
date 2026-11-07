import Foundation
import Testing
@testable import NoSlopKit

private func video(
    _ id: String,
    live: Bool = false,
    upcoming: Bool = false,
    short: Bool = false,
    membersOnly: Bool = false,
    channel: String? = nil,
    title: String? = nil
) -> VideoSummary {
    VideoSummary(
        id: id,
        title: title ?? "Video \(id)",
        channel: channel.map { ChannelRef(id: $0, name: "Channel \($0)") },
        isLive: live,
        isUpcoming: upcoming,
        isShort: short,
        isMembersOnly: membersOnly
    )
}

/// The viewer's filters with `change` applied to the settings.
private func filter(_ change: (inout AppSettings) -> Void) -> ContentFilter {
    var settings = AppSettings()
    change(&settings)
    return ContentFilter(settings: settings)
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

    // MARK: What the viewer does not want to see

    @Test func aBlockedChannelsVideoIsNotAutoplayedAndDoesNotStayUpNext() {
        let blocked = filter { $0.blockedChannels = [BlockedChannel(id: "UCbad", name: "Bad")] }
        let upNext = [video("b", channel: "UCbad"), video("c", channel: "UCok"), video("d", channel: "UCbad"), video("e")]

        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched, allows: { blocked.allows($0) })

        #expect(step?.next.id == "c")
        #expect(ids(step?.remaining ?? []) == ["e"])
    }

    @Test func theFirstSuggestionOfABlockedChannelLeavesTheNextOneToStart() {
        let blocked = filter { $0.blockedChannels = [BlockedChannel(id: "UCbad", name: "Bad")] }
        let upNext = [video("b", channel: "UCbad"), video("c")]

        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched, allows: { blocked.allows($0) })

        #expect(step?.next.id == "c")
        #expect(step?.remaining.isEmpty == true)
    }

    @Test func withoutAPredicateABlockedChannelsVideoStillStarts() {
        // The default allows everything: only the caller that has the viewer's filters can say otherwise.
        let upNext = [video("b", channel: "UCbad"), video("c")]
        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched)
        #expect(step?.next.id == "b")
    }

    @Test func nothingIsStartedWhenTheFiltersRejectEverySuggestion() {
        let blocked = filter { $0.blockedChannels = [BlockedChannel(id: "UCbad", name: "Bad")] }
        let upNext = [video("b", channel: "UCbad"), video("c", channel: "UCbad")]
        #expect(AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched, allows: { blocked.allows($0) }) == nil)
    }

    @Test func membersOnlyVideosAndBlockedKeywordsFollowTheFiltersToo() {
        let strict = filter {
            $0.hideMembersOnly = true
            $0.blockedKeywords = ["unboxing"]
        }
        let upNext = [
            video("b", membersOnly: true),
            video("c", title: "Phone UNBOXING (first look)"),
            video("d", title: "A calm walk"),
        ]

        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched, allows: { strict.allows($0) })

        #expect(step?.next.id == "d")
        #expect(step?.remaining.isEmpty == true)
    }

    @Test func theFiltersTurnedOffLetEverythingThrough() {
        let relaxed = filter {
            $0.hideMembersOnly = false
            $0.hideShorts = false
        }
        let upNext = [video("b", membersOnly: true), video("c")]
        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: nothingWatched, allows: { relaxed.allows($0) })
        #expect(step?.next.id == "b")
        #expect(ids(step?.remaining ?? []) == ["c"])
    }

    @Test func aChannelBlockedBetweenHopsTakesItsVideosOutOfTheListThatWasCarried() {
        // Minimized, no watch page: the list carried from hop to hop is all autoplay has, and a channel blocked since
        // the list was published has to count when it is looked at again.
        let first = AutoplayPlanner.step(
            after: "a",
            upNext: [video("b"), video("c", channel: "UCbad"), video("d"), video("e", channel: "UCbad")],
            progress: nothingWatched
        )
        #expect(first?.next.id == "b")
        #expect(ids(first?.remaining ?? []) == ["c", "d", "e"])

        let blocked = filter { $0.blockedChannels = [BlockedChannel(id: "UCbad", name: "Bad")] }
        let second = AutoplayPlanner.step(
            after: "b",
            upNext: first?.remaining ?? [],
            progress: nothingWatched,
            allows: { blocked.allows($0) }
        )
        #expect(second?.next.id == "d")
        #expect(second?.remaining.isEmpty == true)
    }

    @Test func aVideoTheFiltersAllowStillNeedsToBeUnwatchedAndStartable() {
        let all: (VideoSummary) -> Bool = { _ in true }
        let upNext = [video("b"), video("s", short: true), video("c")]
        let step = AutoplayPlanner.step(after: "a", upNext: upNext, progress: { $0 == "b" ? 300 : nil }, allows: all)
        #expect(step?.next.id == "c")
        #expect(step?.remaining.isEmpty == true)
    }

    // MARK: Videos started in this run

    @Test func aVideoStartedInThisRunIsNotSuggestedAgainWhateverItsProgress() {
        // a was skipped after 4 s, b after 3 s; b's own list starts with a.
        let progress: (String) -> Double? = { ["a": 4, "b": 3][$0] }
        let upNext = [video("a"), video("c")]
        let step = AutoplayPlanner.step(after: "b", upNext: upNext, progress: progress, startedThisRun: ["a", "b"])
        #expect(step?.next.id == "c")
        #expect(step?.remaining.isEmpty == true)
    }

    @Test func withoutTheRunTheTenSecondRuleAloneApplies() {
        let progress: (String) -> Double? = { ["a": 4][$0] }
        let step = AutoplayPlanner.step(after: "b", upNext: [video("a"), video("c")], progress: progress)
        #expect(step?.next.id == "a")
    }

    @Test func nextNeverRevisitsAVideoOfTheRun() {
        let lists: [String: [VideoSummary]] = [
            "a": [video("b"), video("c")],
            "b": [video("a"), video("c")],
            "c": [video("b"), video("d")],
        ]
        var run: Set<String> = ["a"]
        var current = "a"
        var sequence: [String] = []
        for _ in 0..<3 {
            guard let step = AutoplayPlanner.step(
                after: current, upNext: lists[current] ?? [], progress: { _ in 4 }, startedThisRun: run
            ) else { break }
            current = step.next.id
            run.insert(current)
            sequence.append(current)
        }
        #expect(sequence == ["b", "c", "d"])
    }
}
