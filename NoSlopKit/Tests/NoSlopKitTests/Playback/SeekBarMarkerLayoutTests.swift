import Foundation
import Testing
@testable import NoSlopKit

@Suite struct SeekBarMarkerLayoutTests {
    private func segment(
        _ start: Double,
        _ end: Double,
        category: SponsorCategory = .sponsor,
        action: SegmentActionType = .skip
    ) -> SponsorSegment {
        SponsorSegment(id: "s-\(start)-\(end)", category: category, actionType: action, start: start, end: end)
    }

    // MARK: Moments (highlights)

    @Test func aRealHighlightIsATickCentredOnItsMoment() throws {
        // Wj0U4i1wL0U in the SponsorBlock fixture: poi_highlight at [7.451, 7.451] in a 33.181 s video.
        let segments = try SponsorBlockClient.parse(Fixture.data("sponsorblock_prefix.json"), videoID: "Wj0U4i1wL0U")
        let highlight = try #require(segments.first { $0.category == .poiHighlight })
        #expect(highlight.start == 7.451)
        #expect(highlight.end == 7.451)

        let frame = try #require(SeekBarMarkerLayout.frame(for: highlight, duration: 33.181, width: 300))
        #expect(frame.width >= 3)
        #expect(frame.width == SeekBarMarkerLayout.momentWidth)
        #expect(abs(frame.x + frame.width / 2 - 300 * 7.451 / 33.181) < 1e-9)
        #expect(frame.x >= 0)
        #expect(frame.x + frame.width <= 300)
    }

    @Test func aHighlightAtTheStartAndAtTheEndStaysInsideTheBar() throws {
        let atStart = try #require(SeekBarMarkerLayout.frame(for: segment(0, 0, category: .poiHighlight, action: .poi), duration: 200, width: 300))
        #expect(atStart == .init(x: 0, width: 4))

        let atEnd = try #require(SeekBarMarkerLayout.frame(for: segment(200, 200, category: .poiHighlight, action: .poi), duration: 200, width: 300))
        #expect(atEnd == .init(x: 296, width: 4))
    }

    @Test func aHighlightInTheMiddleIsCentred() throws {
        let frame = try #require(SeekBarMarkerLayout.frame(for: segment(90, 90, category: .poiHighlight, action: .poi), duration: 180, width: 300))
        #expect(frame == .init(x: 148, width: 4))
    }

    @Test func aHighlightPastTheEndOrBeforeTheStartIsNotDrawn() {
        #expect(SeekBarMarkerLayout.frame(for: segment(214, 214, category: .poiHighlight, action: .poi), duration: 213, width: 300) == nil)
        #expect(SeekBarMarkerLayout.frame(for: segment(-1, -1, category: .poiHighlight, action: .poi), duration: 213, width: 300) == nil)
    }

    @Test func aTickNeverGetsWiderThanTheBar() throws {
        let frame = try #require(SeekBarMarkerLayout.frame(for: segment(5, 5, category: .poiHighlight, action: .poi), duration: 10, width: 3))
        #expect(frame == .init(x: 0, width: 3))
    }

    // MARK: Stretches

    @Test func aStretchIsDrawnFromItsStartForItsLength() throws {
        // The default mock sponsor: 30 to 45 s of 213 s in a 300 pt bar.
        let frame = try #require(SeekBarMarkerLayout.frame(for: segment(30, 45), duration: 213, width: 300))
        #expect(abs(frame.x - 300 * 30 / 213) < 1e-9)
        #expect(abs(frame.width - 300 * 15 / 213) < 1e-9)
        #expect(abs(frame.x - 42.25) < 0.01)
        #expect(abs(frame.width - 21.13) < 0.01)
    }

    @Test func aVeryShortStretchIsStillTwoPointsWide() throws {
        let frame = try #require(SeekBarMarkerLayout.frame(for: segment(100, 101), duration: 3_600, width: 300))
        #expect(frame.width == SeekBarMarkerLayout.minimumStretchWidth)
        #expect(abs(frame.x - 300 * 100 / 3_600) < 1e-9)
    }

    @Test func aStretchThatRunsPastTheEndStopsAtTheEdge() throws {
        let frame = try #require(SeekBarMarkerLayout.frame(for: segment(200, 260), duration: 213, width: 300))
        #expect(abs(frame.x - 300 * 200 / 213) < 1e-9)
        #expect(abs(frame.x + frame.width - 300) < 1e-9)
    }

    @Test func aStretchBeyondTheEndIsNotDrawn() {
        #expect(SeekBarMarkerLayout.frame(for: segment(250, 260), duration: 213, width: 300) == nil)
    }

    @Test func aSegmentThatEndsBeforeItStartsIsNotDrawn() {
        #expect(SeekBarMarkerLayout.frame(for: segment(50, 40), duration: 213, width: 300) == nil)
    }

    // MARK: Nothing to place them on

    @Test func nothingIsDrawnWhileTheLengthOfTheVideoIsUnknown() {
        for duration in [0.0, -5, .nan, .infinity] {
            #expect(SeekBarMarkerLayout.frame(for: segment(30, 45), duration: duration, width: 300) == nil, "\(duration)")
            #expect(SeekBarMarkerLayout.frame(for: segment(7, 7, category: .poiHighlight, action: .poi), duration: duration, width: 300) == nil, "\(duration)")
        }
    }

    @Test func nothingIsDrawnInABarWithoutWidth() {
        for width in [0.0, -1, .nan] {
            #expect(SeekBarMarkerLayout.frame(for: segment(30, 45), duration: 213, width: width) == nil, "\(width)")
            #expect(SeekBarMarkerLayout.frame(for: segment(7, 7, category: .poiHighlight, action: .poi), duration: 213, width: width) == nil, "\(width)")
        }
    }

    @Test func everySegmentThePlannerShowsHasAPlaceOnTheBar() {
        let segments = [
            segment(30, 45),
            segment(7, 7, category: .poiHighlight, action: .poi),
            segment(120, 130, category: .selfpromo),
        ]
        let planner = SegmentSkipPlanner(segments: segments, behaviors: [:])
        #expect(planner.visibleSegments.count == 3)
        for visible in planner.visibleSegments {
            #expect(SeekBarMarkerLayout.frame(for: visible, duration: 213, width: 300) != nil, "\(visible.category)")
        }
    }
}
