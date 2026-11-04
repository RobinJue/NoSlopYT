import Foundation
import Testing
@testable import NoSlopKit

private func segment(
    _ id: String,
    _ category: SponsorCategory = .sponsor,
    _ start: Double,
    _ end: Double,
    action: SegmentActionType = .skip,
    videoDuration: Double? = nil
) -> SponsorSegment {
    SponsorSegment(id: id, category: category, actionType: action, start: start, end: end, videoDuration: videoDuration)
}

@Suite struct SegmentSkipPlannerTests {
    // MARK: Auto-skip window

    @Test func autoSkipSegmentIsSkippedFromItsStartUntilHalfASecondBeforeItsEnd() {
        let s = segment("a", .sponsor, 10, 20)
        let planner = SegmentSkipPlanner(segments: [s], behaviors: [.sponsor: .autoSkip])

        #expect(planner.segmentToSkip(at: 9.9, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: 10.0, alreadySkipped: []) == s)
        #expect(planner.segmentToSkip(at: 15, alreadySkipped: []) == s)
        #expect(planner.segmentToSkip(at: 19.4, alreadySkipped: []) == s)
        // t must be < end - 0.5
        #expect(planner.segmentToSkip(at: 19.5, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: 19.6, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: 20, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: 500, alreadySkipped: []) == nil)
    }

    @Test func aSegmentThatWasAlreadySkippedIsLeftAlone() {
        let s = segment("a", .sponsor, 10, 20)
        let planner = SegmentSkipPlanner(segments: [s], behaviors: [.sponsor: .autoSkip])

        #expect(planner.segmentToSkip(at: 12, alreadySkipped: ["a"]) == nil)
        #expect(planner.segmentToSkip(at: 12, alreadySkipped: ["other"]) == s)
    }

    @Test func nonFiniteTimesNeverSkip() {
        let planner = SegmentSkipPlanner(segments: [segment("a", .sponsor, 10, 20)], behaviors: [.sponsor: .autoSkip])
        #expect(planner.segmentToSkip(at: .nan, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: .infinity, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: -1, alreadySkipped: []) == nil)
    }

    // MARK: Behaviours

    @Test func showInBarNeverSkipsButIsVisible() {
        let s = segment("a", .intro, 10, 20)
        let planner = SegmentSkipPlanner(segments: [s], behaviors: [.intro: .showInBar])

        #expect(planner.segmentToSkip(at: 12, alreadySkipped: []) == nil)
        #expect(planner.visibleSegments == [s])
    }

    @Test func ignoreIsNeitherSkippedNorVisible() {
        let planner = SegmentSkipPlanner(segments: [segment("a", .sponsor, 10, 20)], behaviors: [.sponsor: .ignore])

        #expect(planner.segmentToSkip(at: 12, alreadySkipped: []) == nil)
        #expect(planner.visibleSegments.isEmpty)
    }

    @Test func autoSkipSegmentsAreVisibleToo() {
        let s = segment("a", .sponsor, 10, 20)
        #expect(SegmentSkipPlanner(segments: [s], behaviors: [.sponsor: .autoSkip]).visibleSegments == [s])
    }

    @Test func highlightsAreNeverAutoSkipped() {
        let byCategory = segment("h", .poiHighlight, 10, 20)
        let byAction = segment("p", .sponsor, 30, 40, action: .poi)
        let planner = SegmentSkipPlanner(
            segments: [byCategory, byAction],
            behaviors: [.poiHighlight: .autoSkip, .sponsor: .autoSkip]
        )

        #expect(planner.segmentToSkip(at: 12, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: 35, alreadySkipped: []) == nil)
        #expect(planner.visibleSegments == [byCategory, byAction])
    }

    @Test func aPointOfInterestIsVisibleEvenThoughItHasNoLength() {
        let point = segment("p", .poiHighlight, 50, 50, action: .poi)
        let planner = SegmentSkipPlanner(segments: [point], behaviors: [.poiHighlight: .showInBar])
        #expect(planner.visibleSegments == [point])
        #expect(planner.segmentToSkip(at: 50, alreadySkipped: []) == nil)
    }

    @Test func segmentsShorterThanASecondAreNeverSkipped() {
        let short = segment("short", .sponsor, 10, 10.9)
        let justEnough = segment("ok", .sponsor, 30, 31)
        let planner = SegmentSkipPlanner(segments: [short, justEnough], behaviors: [.sponsor: .autoSkip])

        #expect(planner.segmentToSkip(at: 10.1, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: 30.2, alreadySkipped: []) == justEnough)
    }

    @Test func categoriesWithoutAConfiguredBehaviourUseTheDefaults() {
        let sponsor = segment("s", .sponsor, 10, 20)
        let intro = segment("i", .intro, 30, 40)
        let planner = SegmentSkipPlanner(segments: [sponsor, intro], behaviors: [:])

        // Defaults: sponsor, selfpromo, interaction skip; every other category shows in the bar.
        #expect(planner.segmentToSkip(at: 12, alreadySkipped: []) == sponsor)
        #expect(planner.segmentToSkip(at: 35, alreadySkipped: []) == nil)
        #expect(planner.visibleSegments == [sponsor, intro])
    }

    @Test func eachCategoryFollowsItsOwnBehaviour() {
        let sponsor = segment("s", .sponsor, 10, 20)
        let selfpromo = segment("p", .selfpromo, 30, 40)
        let interaction = segment("i", .interaction, 50, 60)
        let planner = SegmentSkipPlanner(
            segments: [sponsor, selfpromo, interaction],
            behaviors: [.sponsor: .autoSkip, .selfpromo: .showInBar, .interaction: .ignore]
        )

        #expect(planner.segmentToSkip(at: 12, alreadySkipped: []) == sponsor)
        #expect(planner.segmentToSkip(at: 32, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: 52, alreadySkipped: []) == nil)
        #expect(planner.visibleSegments == [sponsor, selfpromo])
    }

    // MARK: Several segments

    @Test func visibleSegmentsComeInPlaybackOrder() {
        let late = segment("late", .outro, 300, 330)
        let early = segment("early", .intro, 0, 15)
        let middle = segment("middle", .sponsor, 100, 130)
        let planner = SegmentSkipPlanner(
            segments: [late, early, middle],
            behaviors: [.outro: .showInBar, .intro: .showInBar, .sponsor: .autoSkip]
        )
        #expect(planner.visibleSegments.map(\.id) == ["early", "middle", "late"])
    }

    @Test func overlappingSegmentsAreClearedByTheOneThatEndsLast() {
        let first = segment("first", .sponsor, 10, 20)
        let second = segment("second", .selfpromo, 18, 30)
        let planner = SegmentSkipPlanner(segments: [first, second], behaviors: [.sponsor: .autoSkip, .selfpromo: .autoSkip])

        #expect(planner.segmentToSkip(at: 12, alreadySkipped: []) == first)
        #expect(planner.segmentToSkip(at: 19, alreadySkipped: []) == second)
        // After skipping `first` the player stands at 20, inside `second`.
        #expect(planner.segmentToSkip(at: 20, alreadySkipped: ["first"]) == second)
        #expect(planner.segmentToSkip(at: 20, alreadySkipped: ["first", "second"]) == nil)
    }

    @Test func malformedSegmentsAreIgnored() {
        let good = segment("good", .sponsor, 10, 20)
        let planner = SegmentSkipPlanner(
            segments: [
                segment("backwards", .sponsor, 50, 40),
                segment("nan", .sponsor, .nan, 70),
                segment("infinite", .sponsor, 60, .infinity),
                segment("negative", .sponsor, -5, 5),
                good,
            ],
            behaviors: [.sponsor: .autoSkip]
        )

        #expect(planner.visibleSegments == [good])
        #expect(planner.segmentToSkip(at: 2, alreadySkipped: []) == nil)
        #expect(planner.segmentToSkip(at: 45, alreadySkipped: []) == nil)
    }

    @Test func wholeVideoAndChapterLabelsAreNotTimeRanges() {
        let full = segment("full", .sponsor, 0, 0, action: .full)
        let chapter = segment("chapter", .sponsor, 10, 20, action: .chapter)
        let planner = SegmentSkipPlanner(segments: [full, chapter], behaviors: [.sponsor: .autoSkip])

        #expect(planner.visibleSegments.isEmpty)
        #expect(planner.segmentToSkip(at: 12, alreadySkipped: []) == nil)
    }

    @Test func muteSegmentsAreSkippedLikeSkipSegments() {
        // The player has no muting, so the next best thing for a category set to "auto skip" is to jump over it.
        let mute = segment("mute", .sponsor, 10, 20, action: .mute)
        let planner = SegmentSkipPlanner(segments: [mute], behaviors: [.sponsor: .autoSkip])
        #expect(planner.segmentToSkip(at: 12, alreadySkipped: []) == mute)
        #expect(planner.visibleSegments == [mute])
    }

    @Test func noSegmentsMeansNothingToDo() {
        let planner = SegmentSkipPlanner(segments: [], behaviors: AppSettings.defaultSegmentBehaviors)
        #expect(planner.segmentToSkip(at: 12, alreadySkipped: []) == nil)
        #expect(planner.visibleSegments.isEmpty)
    }

    // MARK: Another cut of the video

    /// A segment submitted for a video of another length is from another cut of it (trimmed or re-edited under the
    /// same id): its times point somewhere else now, so it is neither skipped nor drawn.
    @Test func aSegmentOfAnotherCutIsNeitherSkippedNorDrawn() {
        let old = segment("old", .sponsor, 100, 160, videoDuration: 600)
        let planner = SegmentSkipPlanner(segments: [old], behaviors: [.sponsor: .autoSkip], videoLength: 540)

        #expect(planner.segmentToSkip(at: 120, alreadySkipped: []) == nil)
        #expect(planner.visibleSegments.isEmpty)
    }

    @Test func aSegmentOfAnotherCutIsNotDrawnWhateverItsBehaviour() {
        let old = segment("old", .intro, 0, 15, videoDuration: 600)
        let planner = SegmentSkipPlanner(segments: [old], behaviors: [.intro: .showInBar], videoLength: 540)
        #expect(planner.visibleSegments.isEmpty)

        let highlight = segment("point", .poiHighlight, 50, 50, action: .poi, videoDuration: 600)
        let pointPlanner = SegmentSkipPlanner(segments: [highlight], behaviors: [.poiHighlight: .showInBar], videoLength: 540)
        #expect(pointPlanner.visibleSegments.isEmpty)
    }

    @Test func aLengthWithinTwoSecondsIsTheSameCut() {
        let s = segment("a", .sponsor, 100, 160, videoDuration: 600)
        // Exactly two seconds apart, in both directions, is still the same cut; so is anything closer.
        for length in [598.0, 598.5, 600, 601.5, 602] {
            let planner = SegmentSkipPlanner(segments: [s], behaviors: [.sponsor: .autoSkip], videoLength: length)
            #expect(planner.segmentToSkip(at: 120, alreadySkipped: []) == s, "length \(length)")
            #expect(planner.visibleSegments == [s], "length \(length)")
        }
    }

    @Test func aLengthMoreThanTwoSecondsApartIsAnotherCut() {
        let s = segment("a", .sponsor, 100, 160, videoDuration: 600)
        for length in [597.9, 597, 602.1, 603, 585, 1200] {
            let planner = SegmentSkipPlanner(segments: [s], behaviors: [.sponsor: .autoSkip], videoLength: length)
            #expect(planner.segmentToSkip(at: 120, alreadySkipped: []) == nil, "length \(length)")
            #expect(planner.visibleSegments.isEmpty, "length \(length)")
        }
    }

    @Test func withoutAKnownLengthNothingIsDropped() {
        let s = segment("a", .sponsor, 100, 160, videoDuration: 600)
        // Not known yet (nil), or not usable (zero, negative, not a number).
        for length in [nil, 0, -5, Double.nan, Double.infinity] as [Double?] {
            let planner = SegmentSkipPlanner(segments: [s], behaviors: [.sponsor: .autoSkip], videoLength: length)
            #expect(planner.segmentToSkip(at: 120, alreadySkipped: []) == s, "length \(String(describing: length))")
            #expect(planner.visibleSegments == [s], "length \(String(describing: length))")
        }
        // The default: no length given.
        let planner = SegmentSkipPlanner(segments: [s], behaviors: [.sponsor: .autoSkip])
        #expect(planner.segmentToSkip(at: 120, alreadySkipped: []) == s)
    }

    @Test func aSegmentWithoutASubmittedLengthIsNeverDropped() {
        // Nil and zero mean "unknown" (older submissions carry 0); not a different cut.
        let unknown = segment("unknown", .sponsor, 100, 160)
        let zero = segment("zero", .sponsor, 200, 260, videoDuration: 0)
        let negative = segment("negative", .sponsor, 300, 360, videoDuration: -1)
        let notANumber = segment("nan", .sponsor, 400, 460, videoDuration: .nan)
        let planner = SegmentSkipPlanner(
            segments: [unknown, zero, negative, notANumber],
            behaviors: [.sponsor: .autoSkip],
            videoLength: 540
        )

        #expect(planner.visibleSegments.map(\.id) == ["unknown", "zero", "negative", "nan"])
        #expect(planner.segmentToSkip(at: 120, alreadySkipped: []) == unknown)
        #expect(planner.segmentToSkip(at: 220, alreadySkipped: []) == zero)
    }

    @Test func onlyTheSegmentsOfAnotherCutAreDroppedFromAMixedList() {
        let current = segment("current", .sponsor, 100, 160, videoDuration: 540.4)
        let old = segment("old", .selfpromo, 200, 230, videoDuration: 600)
        let unknown = segment("unknown", .interaction, 300, 310)
        let planner = SegmentSkipPlanner(
            segments: [old, unknown, current],
            behaviors: [.sponsor: .autoSkip, .selfpromo: .autoSkip, .interaction: .showInBar],
            videoLength: 540
        )

        #expect(planner.visibleSegments.map(\.id) == ["current", "unknown"])
        #expect(planner.segmentToSkip(at: 120, alreadySkipped: []) == current)
        #expect(planner.segmentToSkip(at: 210, alreadySkipped: []) == nil)
    }
}
