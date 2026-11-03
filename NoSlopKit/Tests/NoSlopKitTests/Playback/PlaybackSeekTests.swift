import Foundation
import Testing
@testable import NoSlopKit

private func segment(
    _ start: Double,
    _ end: Double,
    id: String = "s",
    category: SponsorCategory = .sponsor
) -> SponsorSegment {
    SponsorSegment(id: id, category: category, actionType: .skip, start: start, end: end)
}

@Suite struct PlaybackSeekTests {
    // MARK: Limits of a seek

    @Test func theEndMarginIsAQuarterOfASecond() {
        #expect(PlaybackSeek.endMargin == 0.25)
    }

    @Test func aSeekToOrPastTheEndLandsOnTheMarginBeforeIt() {
        #expect(PlaybackSeek.clamped(600, duration: 600, isLive: false) == 599.75)
        #expect(PlaybackSeek.clamped(610, duration: 600, isLive: false) == 599.75)
        #expect(PlaybackSeek.clamped(599.9, duration: 600, isLive: false) == 599.75)
        #expect(PlaybackSeek.clamped(.greatestFiniteMagnitude, duration: 600, isLive: false) == 599.75)
    }

    @Test func aSeekInsideTheVideoIsLeftAlone() {
        #expect(PlaybackSeek.clamped(0, duration: 600, isLive: false) == 0)
        #expect(PlaybackSeek.clamped(45, duration: 600, isLive: false) == 45)
        #expect(PlaybackSeek.clamped(599.75, duration: 600, isLive: false) == 599.75)
    }

    @Test func aSeekBeforeTheStartLandsOnTheStart() {
        #expect(PlaybackSeek.clamped(-5, duration: 600, isLive: false) == 0)
        #expect(PlaybackSeek.clamped(-.infinity, duration: 600, isLive: false) == 0)
    }

    @Test func anUnknownDurationHasNoUpperLimit() {
        #expect(PlaybackSeek.clamped(5_000, duration: 0, isLive: false) == 5_000)
        #expect(PlaybackSeek.clamped(5_000, duration: .nan, isLive: false) == 5_000)
        #expect(PlaybackSeek.clamped(5_000, duration: -1, isLive: false) == 5_000)
    }

    @Test func aLiveStreamHasNoEnd() {
        #expect(PlaybackSeek.clamped(5_000, duration: 600, isLive: true) == 5_000)
    }

    @Test func aTimeThatIsNotANumberGoesToTheStart() {
        #expect(PlaybackSeek.clamped(.nan, duration: 600, isLive: false) == 0)
        #expect(PlaybackSeek.clamped(.infinity, duration: 600, isLive: false) == 0)
    }

    @Test func aVideoShorterThanTheMarginStartsAtZero() {
        #expect(PlaybackSeek.clamped(0.2, duration: 0.1, isLive: false) == 0)
    }

    // MARK: Skipping a segment

    @Test func skippingLandsOnTheEndOfTheSegment() {
        let sponsor = segment(30, 45)
        #expect(PlaybackSeek.skipDestination(of: sponsor, from: 30, duration: 213, isLive: false) == 45)
        #expect(PlaybackSeek.skipDestination(of: sponsor, from: 44.4, duration: 213, isLive: false) == 45)
    }

    @Test func aSegmentThatRunsToTheEndLandsOnTheEndMargin() {
        let outro = segment(590, 600, id: "outro")
        #expect(PlaybackSeek.skipDestination(of: outro, from: 595, duration: 600, isLive: false) == 599.75)
    }

    @Test func aSegmentThatRunsPastTheEndAlsoLandsOnTheEndMargin() {
        let outro = segment(590, 612, id: "outro")
        #expect(PlaybackSeek.skipDestination(of: outro, from: 595, duration: 600, isLive: false) == 599.75)
    }

    @Test func noJumpWhenPlaybackIsAlreadyWithinTheEndMargin() {
        let outro = segment(590, 612, id: "outro")
        #expect(PlaybackSeek.skipDestination(of: outro, from: 599.75, duration: 600, isLive: false) == nil)
        #expect(PlaybackSeek.skipDestination(of: outro, from: 599.9, duration: 600, isLive: false) == nil)
        #expect(PlaybackSeek.skipDestination(of: outro, from: 599.71, duration: 600, isLive: false) == nil)
        // A jump of 60 ms is still a jump.
        #expect(PlaybackSeek.skipDestination(of: outro, from: 599.69, duration: 600, isLive: false) == 599.75)
    }

    @Test func noJumpFromATimeThatIsNotANumber() {
        #expect(PlaybackSeek.skipDestination(of: segment(30, 45), from: .nan, duration: 213, isLive: false) == nil)
    }

    // MARK: With the real planner (SponsorBlock, Task 6)

    /// What the player does on a tick of its clock while a video plays, reduced to times: skip what the planner names,
    /// otherwise play on half a second. Returns the skips, and the time at which the video had played to its end.
    private func playOut(
        _ planner: SegmentSkipPlanner,
        from start: Double,
        duration: Double,
        declined: Set<String> = []
    ) -> (skips: [SponsorSegment], endedAt: Double?) {
        var time = start
        var skips: [SponsorSegment] = []
        var ticks = 0
        while time < duration, ticks < 10_000 {
            ticks += 1
            if let segment = planner.segmentToSkip(at: time, alreadySkipped: declined),
               let destination = PlaybackSeek.skipDestination(of: segment, from: time, duration: duration, isLive: false) {
                skips.append(segment)
                time = destination
            } else {
                time += 0.5
            }
        }
        return (skips, time >= duration ? time : nil)
    }

    @Test func theMockSponsorSegmentIsSkippedToFortyFiveSecondsOnce() {
        // `-openURL 'noslop://watch?v=aqz-KE-bpKQ&t=27'` with MockSponsorBlock's segments.
        let planner = SegmentSkipPlanner(segments: SampleData.segments, behaviors: AppSettings.defaultSegmentBehaviors)
        var time = 27.0
        var landings: [Double] = []
        while time < 60 {
            if let found = planner.segmentToSkip(at: time, alreadySkipped: []),
               let destination = PlaybackSeek.skipDestination(of: found, from: time, duration: 213, isLive: false) {
                landings.append(destination)
                time = destination
            } else {
                time += 0.5
            }
        }
        #expect(landings == [45])
    }

    @Test func undoReturnsToTheStartAndTheSegmentIsNotSkippedAgain() {
        let sponsor = SampleData.segments[0]
        let planner = SegmentSkipPlanner(segments: [sponsor], behaviors: AppSettings.defaultSegmentBehaviors)
        #expect(planner.segmentToSkip(at: sponsor.start, alreadySkipped: []) == sponsor)
        // Undo seeks back to the start and remembers the id.
        #expect(planner.segmentToSkip(at: sponsor.start, alreadySkipped: [sponsor.id]) == nil)
        #expect(planner.segmentToSkip(at: sponsor.start + 7, alreadySkipped: [sponsor.id]) == nil)
        #expect(playOut(planner, from: sponsor.start, duration: 213, declined: [sponsor.id]).skips.isEmpty)
    }

    @Test func aSegmentEndingAtTheEndOfTheVideoIsSkippedOnceAndPlaybackReachesTheEnd() {
        let outro = segment(590, 600, id: "outro")
        let planner = SegmentSkipPlanner(segments: [outro], behaviors: [.sponsor: .autoSkip])

        // The skip lands on the end margin, where the planner leaves it alone ...
        #expect(planner.segmentToSkip(at: 599.75, alreadySkipped: []) == nil)

        // ... so the video plays out its last quarter second and ends the usual way.
        let result = playOut(planner, from: 580, duration: 600)
        #expect(result.skips == [outro])
        #expect(result.endedAt != nil)
    }

    @Test func aSegmentEndingJustPastTheEndIsStillSkippedOnce() {
        for end in [600.2, 600.4, 600.75, 601, 700] {
            let outro = segment(590, end, id: "outro")
            let planner = SegmentSkipPlanner(segments: [outro], behaviors: [.sponsor: .autoSkip])
            let result = playOut(planner, from: 580, duration: 600)
            #expect(result.skips.count == 1, "segment ending at \(end)")
            #expect(result.endedAt != nil, "segment ending at \(end)")
        }
    }

    @Test func playbackThatStartsInsideTheLastSegmentSkipsToTheEndAndEnds() {
        let outro = segment(590, 600, id: "outro")
        let planner = SegmentSkipPlanner(segments: [outro], behaviors: [.sponsor: .autoSkip])
        let result = playOut(planner, from: 596, duration: 600)
        #expect(result.skips == [outro])
        #expect(result.endedAt != nil)
    }

    @Test func aSegmentThatEndsExactlyAtTheEndNeverSendsThePlayheadToTheEndItself() throws {
        let outro = segment(590, 600, id: "outro")
        let destination = try #require(PlaybackSeek.skipDestination(of: outro, from: 590, duration: 600, isLive: false))
        // Exactly at the end AVPlayer would wait for media that never comes.
        #expect(destination < 600)
        #expect(600 - destination == PlaybackSeek.endMargin)
    }
}
