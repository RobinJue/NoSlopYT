import Foundation

/// Builds the on-device "For you" feed from watch history, related videos and fresh subscription uploads.
///
/// STUB (Task 1A). Task 6 owns this file: returns `HomeFeed.empty` until it is filled in.
public actor HomeFeedService: HomeFeedProviding {
    public init(youTube: any YouTubeService, maxSeeds: Int = 6) {}

    public func homeFeed(history: [HistoryEntry], subscriptionVideos: [VideoSummary]) async -> HomeFeed {
        .empty
    }
}
