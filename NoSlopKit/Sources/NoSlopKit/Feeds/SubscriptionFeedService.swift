import Foundation

/// The chronological feed of uploads from all subscribed channels (RSS), cached to disk.
///
/// STUB (Task 1A). Task 6 owns this file: `cachedFeed` is empty and `feed` throws `NoSlopError.notImplemented`.
public actor SubscriptionFeedService: SubscriptionFeedProviding {
    public init(rss: any RSSFeedFetching, account: (any YouTubeAccountService)?, cacheURL: URL?, maxConcurrent: Int = 8) {}

    public func cachedFeed() async -> [VideoSummary] {
        []
    }

    public func feed(channels: [SubscribedChannel], forceRefresh: Bool) async throws -> [VideoSummary] {
        throw NoSlopError.notImplemented("SubscriptionFeedService.feed")
    }
}
