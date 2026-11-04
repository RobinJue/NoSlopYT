import Foundation
import Testing
@testable import NoSlopKit

// What the watch page says about the queue that plays (spec-7): where it came from, where in it the video is, and the
// next few videos of it.

private func video(_ id: String) -> VideoSummary {
    VideoSummary(id: id, title: "Video \(id)")
}

/// The videos "v<n>" for every n in `range`.
private func videos(_ range: Range<Int>) -> [VideoSummary] {
    range.map { video("v\($0)") }
}

@Suite struct QueueOutlineTests {
    // MARK: Position

    @Test func aListLoadedToItsEndHasAKnownTotal() throws {
        // Play all on a list of 14: the first video plays and 13 are queued.
        let outline = try #require(QueueOutline(name: "Road trip", position: 1, queued: videos(1..<14), hasMore: false))

        #expect(outline.total == 14)
        #expect(outline.positionText == "1 of 14")
        #expect(outline.spokenPositionText == "Video 1 of 14")
    }

    @Test func aListThatGoesOnShowsAPlusBehindWhatIsLoaded() throws {
        // The third video of a list whose first 100 are loaded: 97 queued, and more pages may come.
        let outline = try #require(QueueOutline(name: "Liked videos", position: 3, queued: videos(3..<100), hasMore: true))

        #expect(outline.total == 100)
        #expect(outline.positionText == "3 of 100+")
        #expect(outline.spokenPositionText == "Video 3 of at least 100")
    }

    @Test func theLastVideoOfAQueueIsNOfN() throws {
        let last = try #require(QueueOutline(name: "Road trip", position: 14, queued: [], hasMore: false))
        #expect(last.positionText == "14 of 14")
        #expect(last.upcoming.isEmpty)

        // At the end of what is loaded, with the next page still to come.
        let loadedEnd = try #require(QueueOutline(name: "Road trip", position: 100, queued: [], hasMore: true))
        #expect(loadedEnd.positionText == "100 of 100+")
    }

    @Test func theTotalGrowsWhenAPageArrives() throws {
        let before = try #require(QueueOutline(name: "Long list", position: 99, queued: videos(99..<100), hasMore: true))
        #expect(before.positionText == "99 of 100+")

        // The next page of 100 came in behind the queue: same position, more videos.
        let after = try #require(QueueOutline(name: "Long list", position: 99, queued: videos(99..<200), hasMore: true))
        #expect(after.positionText == "99 of 200+")

        // ...and it was the last page: the total is known now.
        let done = try #require(QueueOutline(name: "Long list", position: 99, queued: videos(99..<200), hasMore: false))
        #expect(done.positionText == "99 of 200")
    }

    @Test func noQueueHasNoOutline() {
        #expect(QueueOutline(name: "Anything", position: 0, queued: videos(0..<5), hasMore: true) == nil)
        #expect(QueueOutline(name: nil, position: -1, queued: [], hasMore: false) == nil)
    }

    // MARK: The name

    @Test func theTitleSaysWhereTheQueueCameFrom() throws {
        let outline = try #require(QueueOutline(name: "Liked videos", position: 1, queued: videos(1..<3), hasMore: false))
        #expect(outline.name == "Liked videos")
        #expect(outline.title == "Playing from Liked videos")
    }

    @Test func aNameIsTrimmed() throws {
        let outline = try #require(QueueOutline(name: "  Road trip \n", position: 1, queued: videos(1..<3), hasMore: false))
        #expect(outline.name == "Road trip")
        #expect(outline.title == "Playing from Road trip")
    }

    @Test func aQueueWithoutANameStillHasATitle() throws {
        let unnamed = try #require(QueueOutline(name: nil, position: 2, queued: videos(2..<5), hasMore: false))
        #expect(unnamed.name == nil)
        #expect(unnamed.title == "Playing from your queue")

        let blank = try #require(QueueOutline(name: "   ", position: 2, queued: videos(2..<5), hasMore: false))
        #expect(blank.name == nil)
        #expect(blank.title == "Playing from your queue")
    }

    // MARK: What comes next

    @Test func theNextFewQueuedVideosAreListedInOrder() throws {
        let outline = try #require(QueueOutline(name: "Road trip", position: 1, queued: videos(1..<10), hasMore: false))

        #expect(QueueOutline.upcomingLimit == 3)
        #expect(outline.upcoming.map(\.id) == ["v1", "v2", "v3"])
    }

    @Test func fewerQueuedVideosThanTheLimitAreAllListed() throws {
        let two = try #require(QueueOutline(name: nil, position: 5, queued: videos(5..<7), hasMore: false))
        #expect(two.upcoming.map(\.id) == ["v5", "v6"])

        let none = try #require(QueueOutline(name: nil, position: 5, queued: [], hasMore: true))
        #expect(none.upcoming.isEmpty)
    }

    @Test func theTotalCountsEveryQueuedVideoNotOnlyTheListedOnes() throws {
        let outline = try #require(QueueOutline(name: nil, position: 2, queued: videos(2..<50), hasMore: false))

        #expect(outline.upcoming.count == 3)
        #expect(outline.queuedCount == 48)
        #expect(outline.total == 50)
    }
}
