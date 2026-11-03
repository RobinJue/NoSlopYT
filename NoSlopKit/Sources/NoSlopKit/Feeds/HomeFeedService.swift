import Foundation

/// Builds the on-device "For you" feed from watch history, related videos and fresh subscription uploads.
///
/// - **Continue watching**: history entries that are at least 30 s in, not finished and not Shorts; the 10 most
///   recent, in the order of `history` (most recent first, as `LibraryStore` keeps it).
/// - **For you**: the *seeds* are the most recent distinct non-Short history entries (up to `maxSeeds`). Their watch
///   pages are fetched concurrently (failures and slow answers are skipped) and the first 12 related videos of each are
///   dealt out round-robin, so every seed gets a turn. Videos already in the history, and repeats, are dropped.
///   Uploads from subscriptions that are less than a week old and not in the history take every third slot
///   (indices 2, 5, 8, ...); once one of the two kinds runs out the other fills the remaining slots. At most 60 videos.
/// - Without anything to recommend from (no history, or YouTube cannot be reached) "For you" is simply the latest
///   subscription videos that are not in the history.
///
/// The result is not filtered: Shorts, blocked channels and so on are `ContentFilter`'s business.
public actor HomeFeedService: HomeFeedProviding {
    private static let relatedPerSeed = 12
    private static let continueWatchingLimit = 10
    private static let minimumContinueWatchingSeconds = 30.0
    private static let feedLimit = 60
    private static let freshnessWindow: TimeInterval = 7 * 24 * 60 * 60

    private let youTube: any YouTubeService
    private let maxSeeds: Int
    private let fetchTimeout: Duration
    private let now: @Sendable () -> Date

    public init(youTube: any YouTubeService, maxSeeds: Int = 6) {
        self.init(youTube: youTube, maxSeeds: maxSeeds, fetchTimeout: .seconds(12), now: { Date() })
    }

    /// Tests choose how long to wait for the watch pages and the clock.
    init(youTube: any YouTubeService, maxSeeds: Int, fetchTimeout: Duration, now: @escaping @Sendable () -> Date) {
        self.youTube = youTube
        self.maxSeeds = max(0, maxSeeds)
        self.fetchTimeout = fetchTimeout
        self.now = now
    }

    public func homeFeed(history: [HistoryEntry], subscriptionVideos: [VideoSummary]) async -> HomeFeed {
        let continueWatching = history.lazy
            .filter { Self.isWorthResuming($0) }
            .prefix(Self.continueWatchingLimit)
        let related = await relatedLists(for: Self.seedIDs(in: history, limit: maxSeeds))
        let forYou = Self.compose(
            related: related,
            subscriptionVideos: subscriptionVideos,
            historyIDs: Set(history.map(\.id)),
            now: now()
        )
        return HomeFeed(continueWatching: Array(continueWatching), forYou: forYou)
    }

    // MARK: Continue watching

    private static func isWorthResuming(_ entry: HistoryEntry) -> Bool {
        entry.progressSeconds >= minimumContinueWatchingSeconds && !entry.isFinished && !entry.video.isShort
    }

    // MARK: Related videos

    /// The most recent distinct non-Short videos of the history, newest first.
    private static func seedIDs(in history: [HistoryEntry], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var ids: [String] = []
        for entry in history where !entry.video.isShort && seen.insert(entry.id).inserted {
            ids.append(entry.id)
            if ids.count == limit { break }
        }
        return ids
    }

    /// The first related videos of every seed, in the order of the seeds. Seeds that fail or do not answer within
    /// `fetchTimeout` give an empty list.
    private func relatedLists(for seedIDs: [String]) async -> [[VideoSummary]] {
        guard !seedIDs.isEmpty else { return [] }
        let youTube = youTube
        let timeout = fetchTimeout
        let limit = Self.relatedPerSeed

        return await withTaskGroup(of: (index: Int, related: [VideoSummary])?.self) { group in
            for (index, id) in seedIDs.enumerated() {
                group.addTask {
                    let details = try? await youTube.videoDetails(id: id)
                    return (index, Array((details?.related ?? []).prefix(limit)))
                }
            }
            // A nil result is the deadline passing.
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }

            var lists = [[VideoSummary]](repeating: [], count: seedIDs.count)
            var waiting = seedIDs.count
            while waiting > 0, let result = await group.next() {
                guard let (index, related) = result else { break }
                lists[index] = related
                waiting -= 1
            }
            // Stragglers (and the timer, when everything answered in time) are cancelled.
            group.cancelAll()
            return lists
        }
    }

    // MARK: Composing the feed

    private static func compose(
        related lists: [[VideoSummary]],
        subscriptionVideos: [VideoSummary],
        historyIDs: Set<String>,
        now: Date
    ) -> [VideoSummary] {
        var seen = historyIDs

        // Related videos, one from each seed in turn.
        var related: [VideoSummary] = []
        for round in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where round < list.count {
                let video = list[round]
                if seen.insert(video.id).inserted { related.append(video) }
            }
        }

        guard !related.isEmpty else {
            // Nothing to recommend from: the latest subscription videos that were not watched.
            var unseen = historyIDs
            return Array(subscriptionVideos.filter { unseen.insert($0.id).inserted }.prefix(feedLimit))
        }

        let fresh = subscriptionVideos.filter { isFresh($0, now: now) && seen.insert($0.id).inserted }

        var relatedIterator = related.makeIterator()
        var freshIterator = fresh.makeIterator()
        var feed: [VideoSummary] = []
        while feed.count < feedLimit {
            let isSubscriptionSlot = (feed.count + 1) % 3 == 0
            let next = isSubscriptionSlot
                ? freshIterator.next() ?? relatedIterator.next()
                : relatedIterator.next() ?? freshIterator.next()
            guard let video = next else { break }
            feed.append(video)
        }
        return feed
    }

    private static func isFresh(_ video: VideoSummary, now: Date) -> Bool {
        guard let publishedAt = video.publishedAt else { return false }
        return now.timeIntervalSince(publishedAt) <= freshnessWindow
    }
}
