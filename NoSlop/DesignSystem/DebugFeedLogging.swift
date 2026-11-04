#if DEBUG
import NoSlopKit
import OSLog

/// What Home and Subscriptions ask of the feed services, written to the log (category `feeds`, lines that start with
/// "[feeds]"), for simulator checks: when a screen loads, and whether it asks for fresh uploads or makes do with the
/// cache. Mock runs wrap their feed services in the two types below. Compiled out of Release builds.
///
///     xcrun simctl spawn <udid> log stream --level debug --predicate 'subsystem == "com.robinjungerich.noslopyt"'
enum FeedLog {
    nonisolated static let logger = Logger(subsystem: "com.robinjungerich.noslopyt", category: "feeds")

    nonisolated static func info(_ line: String) {
        logger.info("[feeds] \(line, privacy: .public)")
    }
}

nonisolated struct LoggingSubscriptionFeed: SubscriptionFeedProviding {
    let base: any SubscriptionFeedProviding

    init(_ base: any SubscriptionFeedProviding) {
        self.base = base
    }

    func cachedFeed() async -> [VideoSummary] {
        let feed = await base.cachedFeed()
        FeedLog.info("subscriptionFeed.cachedFeed -> \(feed.count) videos")
        return feed
    }

    func feed(channels: [SubscribedChannel], forceRefresh: Bool) async throws -> [VideoSummary] {
        let call = "subscriptionFeed.feed channels=\(channels.count) force=\(forceRefresh)"
        FeedLog.info("\(call) start")
        do {
            let feed = try await base.feed(channels: channels, forceRefresh: forceRefresh)
            FeedLog.info("\(call) -> \(feed.count) videos, newest \(feed.first?.id ?? "-")")
            return feed
        } catch {
            FeedLog.info("\(call) failed: \(error)")
            throw error
        }
    }
}

nonisolated struct LoggingHomeFeed: HomeFeedProviding {
    let base: any HomeFeedProviding

    init(_ base: any HomeFeedProviding) {
        self.base = base
    }

    func homeFeed(history: [HistoryEntry], subscriptionVideos: [VideoSummary]) async -> HomeFeed {
        let call = "homeFeed history=\(history.count) uploads=\(subscriptionVideos.count)"
        FeedLog.info("\(call) start")
        let feed = await base.homeFeed(history: history, subscriptionVideos: subscriptionVideos)
        FeedLog.info(
            "\(call) -> continue=\(feed.continueWatching.count) forYou=\(feed.forYou.count) first \(feed.forYou.first?.id ?? "-") "
                + "unavailable=\(feed.relatedUnavailable)"
        )
        return feed
    }
}
#endif
