import Foundation
import Testing
@testable import NoSlopKit

private func video(_ id: String, channel: String = "UCok") -> VideoSummary {
    VideoSummary(id: id, title: "Video \(id)", channel: ChannelRef(id: channel, name: "Channel \(channel)"))
}

private func ids(_ videos: [VideoSummary]) -> [String] {
    videos.map(\.id)
}

@Suite struct PlaylistQueueStartTests {
    private let list = ["a", "b", "c", "d", "e"].map { video($0) }

    @Test func theVideosAfterTheOpenedOneFollowIt() {
        let start = PlaylistQueueStart.make(videoID: "c", in: list)

        #expect(start.videoWasFound)
        #expect(start.position == 3)
        #expect(ids(start.queued) == ["d", "e"])
    }

    @Test func theFirstVideoQueuesTheRest() {
        let start = PlaylistQueueStart.make(videoID: "a", in: list)

        #expect(start.position == 1)
        #expect(ids(start.queued) == ["b", "c", "d", "e"])
    }

    @Test func theLastVideoQueuesNothing() {
        let start = PlaylistQueueStart.make(videoID: "e", in: list)

        #expect(start.videoWasFound)
        #expect(start.position == 5)
        #expect(start.queued.isEmpty)
    }

    @Test func aVideoThatIsNotInThePlaylistQueuesItFromItsStart() {
        let start = PlaylistQueueStart.make(videoID: "zzz", in: list)

        #expect(!start.videoWasFound)
        #expect(start.position == 1)
        #expect(ids(start.queued) == ["a", "b", "c", "d", "e"])
    }

    @Test func theFiltersApplyToTheVideosBeforeAndAfter() {
        let hideBAndD: ([VideoSummary]) -> [VideoSummary] = { $0.filter { !["b", "d"].contains($0.id) } }
        let start = PlaylistQueueStart.make(videoID: "c", in: list, filter: hideBAndD)

        #expect(start.position == 2)
        #expect(ids(start.queued) == ["e"])
    }

    @Test func theOpenedVideoPlaysEvenWhenTheFiltersWouldHideIt() {
        let hideC: ([VideoSummary]) -> [VideoSummary] = { $0.filter { $0.id != "c" } }
        let start = PlaylistQueueStart.make(videoID: "c", in: list, filter: hideC)

        #expect(start.videoWasFound)
        #expect(start.position == 3)
        #expect(ids(start.queued) == ["d", "e"])
    }

    @Test func aRepeatedVideoIsNotQueuedBehindItself() {
        let repeated = ["a", "b", "a", "c"].map { video($0) }
        let start = PlaylistQueueStart.make(videoID: "a", in: repeated)

        #expect(start.position == 1)
        #expect(ids(start.queued) == ["b", "c"])
    }

    @Test func anEmptyPlaylistQueuesNothing() {
        let start = PlaylistQueueStart.make(videoID: "a", in: [])

        #expect(!start.videoWasFound)
        #expect(start.position == 1)
        #expect(start.queued.isEmpty)
    }
}
