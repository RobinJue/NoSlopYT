import Foundation

/// `RSSFeedFetching` over HTTP: fetches `feeds/videos.xml?channel_id=<id>` and parses it with `RSSParser`.
///
/// STUB (Task 1A). Task 2 owns this file: `latestVideos` throws `NoSlopError.notImplemented`.
public struct RSSFeedFetcher: RSSFeedFetching {
    public init(http: any HTTPClient) {}

    public func latestVideos(channelID: String) async throws -> [VideoSummary] {
        throw NoSlopError.notImplemented("RSSFeedFetcher.latestVideos")
    }
}
