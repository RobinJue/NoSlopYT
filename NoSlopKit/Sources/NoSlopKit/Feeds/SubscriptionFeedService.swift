import Foundation

/// The chronological feed of uploads from all subscribed channels (RSS), cached to disk.
///
/// - Each channel's RSS feed is fetched with at most `maxConcurrent` requests in flight and remembered for 15
///   minutes (`forceRefresh` asks again). A channel that fails does not fail the feed: it contributes the videos it
///   had before (from this session or from the disk cache), or nothing if it never loaded, so a hiccup does not
///   make its uploads vanish. Only when *every* channel fails is the first channel's error thrown, and the cached
///   feed is left as it was.
/// - The merged feed has every video once, newest first (videos without a date last). It is not filtered: Shorts,
///   blocked channels and so on are `ContentFilter`'s business.
/// - RSS has no durations. Videos without one are looked up through the signed-in account's Data API in batches of
///   50; when that fails (not signed in, quota, offline) the feed simply goes without. Durations that were learned
///   once are never asked for again.
/// - After every refresh that produced a feed it is written to `cacheURL`, and `cachedFeed()` serves it for an
///   instant first paint on the next launch.
public actor SubscriptionFeedService: SubscriptionFeedProviding {
    private struct ChannelEntry {
        var videos: [VideoSummary]
        var fetchedAt: Date
    }

    private static let durationBatchSize = 50

    private let rss: any RSSFeedFetching
    private let account: (any YouTubeAccountService)?
    private let store: JSONFileStore?
    private let cacheFile: String
    private let maxConcurrent: Int
    private let channelCacheTTL: TimeInterval
    private let now: @Sendable () -> Date

    /// Per channel id: its videos from the last successful fetch. Entries loaded from the disk cache have no fetch
    /// time (they are only used when a fetch fails).
    private var entries: [String: ChannelEntry] = [:]
    private var knownDurations: [String: Int] = [:]
    private var lastFeed: [VideoSummary] = []
    private var diskCacheLoaded = false

    public init(rss: any RSSFeedFetching, account: (any YouTubeAccountService)?, cacheURL: URL?, maxConcurrent: Int = 8) {
        self.init(
            rss: rss, account: account, cacheURL: cacheURL, maxConcurrent: maxConcurrent,
            channelCacheTTL: 15 * 60, now: { Date() }
        )
    }

    /// Tests choose the per-channel cache lifetime and the clock.
    init(
        rss: any RSSFeedFetching,
        account: (any YouTubeAccountService)?,
        cacheURL: URL?,
        maxConcurrent: Int,
        channelCacheTTL: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.rss = rss
        self.account = account
        self.store = cacheURL.map { JSONFileStore(directory: $0.deletingLastPathComponent()) }
        self.cacheFile = cacheURL?.lastPathComponent ?? ""
        self.maxConcurrent = max(1, maxConcurrent)
        self.channelCacheTTL = channelCacheTTL
        self.now = now
    }

    // MARK: SubscriptionFeedProviding

    public func cachedFeed() async -> [VideoSummary] {
        loadDiskCacheIfNeeded()
        return lastFeed
    }

    public func feed(channels: [SubscribedChannel], forceRefresh: Bool) async throws -> [VideoSummary] {
        loadDiskCacheIfNeeded()

        var seenIDs = Set<String>()
        let channels = channels.filter { seenIDs.insert($0.id).inserted }
        guard !channels.isEmpty else {
            lastFeed = []
            persist([])
            return []
        }

        let startedAt = now()
        let toFetch = channels.filter { channel in
            guard !forceRefresh, let entry = entries[channel.id], entry.fetchedAt != .distantPast else { return true }
            return startedAt.timeIntervalSince(entry.fetchedAt) >= channelCacheTTL
        }
        let outcomes = await fetch(toFetch)
        // Whoever asked has gone away: keep what is cached and do not publish half a refresh.
        if Task.isCancelled { throw NoSlopError.cancelled }

        var firstError: (any Error)?
        var failures = 0
        for (channel, outcome) in zip(toFetch, outcomes) {
            switch outcome {
            case .success(let videos):
                entries[channel.id] = ChannelEntry(videos: Self.attributed(videos, to: channel), fetchedAt: startedAt)
            case .failure(let error):
                failures += 1
                firstError = firstError ?? error
            }
        }
        if failures == channels.count, let firstError {
            throw firstError
        }

        let merged = Self.sortedUnique(channels.flatMap { entries[$0.id]?.videos ?? [] })
        let feed = await fillingDurations(in: merged)
        lastFeed = feed
        persist(feed)
        return feed
    }

    // MARK: Fetching

    /// The RSS videos of `channels`, in the same order; at most `maxConcurrent` requests run at a time.
    private func fetch(_ channels: [SubscribedChannel]) async -> [Result<[VideoSummary], any Error>] {
        let rss = rss
        return await Self.concurrentMap(channels, limit: maxConcurrent) { channel in
            do {
                return .success(try await rss.latestVideos(channelID: channel.id))
            } catch {
                return .failure(error)
            }
        }
    }

    /// Runs `transform` over `inputs`, at most `limit` at a time, and returns the outputs in the order of the inputs.
    private static func concurrentMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        limit: Int,
        _ transform: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        guard !inputs.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            while nextIndex < min(max(1, limit), inputs.count) {
                let index = nextIndex
                let input = inputs[index]
                group.addTask { (index, await transform(input)) }
                nextIndex += 1
            }
            var outputs = [Output?](repeating: nil, count: inputs.count)
            while let (index, output) = await group.next() {
                outputs[index] = output
                if nextIndex < inputs.count {
                    let index = nextIndex
                    let input = inputs[index]
                    group.addTask { (index, await transform(input)) }
                    nextIndex += 1
                }
            }
            return outputs.compactMap { $0 }
        }
    }

    // MARK: Merging

    /// The channel's own information on videos that lack it (RSS has no avatars).
    private static func attributed(_ videos: [VideoSummary], to channel: SubscribedChannel) -> [VideoSummary] {
        videos.map { video in
            var video = video
            if var owner = video.channel {
                if owner.avatarURL == nil, let avatarURL = channel.avatarURL {
                    owner.avatarURL = avatarURL
                    video.channel = owner
                }
            } else {
                video.channel = channel.ref
            }
            return video
        }
    }

    /// Every id once (the first one wins), newest first, undated videos last; ties keep their input order.
    private static func sortedUnique(_ videos: [VideoSummary]) -> [VideoSummary] {
        var seen = Set<String>()
        var unique: [(offset: Int, video: VideoSummary)] = []
        for (offset, video) in videos.enumerated() where seen.insert(video.id).inserted {
            unique.append((offset, video))
        }
        unique.sort { lhs, rhs in
            switch (lhs.video.publishedAt, rhs.video.publishedAt) {
            case let (left?, right?): return left == right ? lhs.offset < rhs.offset : left > right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }
        return unique.map(\.video)
    }

    // MARK: Durations

    private func fillingDurations(in videos: [VideoSummary]) async -> [VideoSummary] {
        var videos = videos
        var missing: [String] = []
        for index in videos.indices where videos[index].durationSeconds == nil {
            if let known = knownDurations[videos[index].id] {
                videos[index].durationSeconds = known
            } else {
                missing.append(videos[index].id)
            }
        }
        guard let account, !missing.isEmpty else { return videos }

        for (id, seconds) in await lookUpDurations(of: missing, with: account) {
            knownDurations[id] = seconds
        }
        for index in videos.indices where videos[index].durationSeconds == nil {
            videos[index].durationSeconds = knownDurations[videos[index].id]
        }
        return videos
    }

    /// Video id -> seconds for the ids the account's Data API knows. Any failure just means fewer durations.
    private func lookUpDurations(of ids: [String], with account: any YouTubeAccountService) async -> [String: Int] {
        let batches = stride(from: 0, to: ids.count, by: Self.durationBatchSize).map { start in
            Array(ids[start..<min(start + Self.durationBatchSize, ids.count)])
        }
        // The first batch goes alone: when the account is signed out (or out of quota) the rest would fail the same way.
        guard let first = batches.first, var found = try? await account.durations(videoIDs: first) else { return [:] }
        let others = await Self.concurrentMap(Array(batches.dropFirst()), limit: maxConcurrent) { batch in
            (try? await account.durations(videoIDs: batch)) ?? [:]
        }
        for batchResult in others {
            found.merge(batchResult) { current, _ in current }
        }
        // 0 is what the API says for live streams and premieres: not a length.
        return found.filter { $0.value > 0 }
    }

    // MARK: Disk cache

    private func loadDiskCacheIfNeeded() {
        guard !diskCacheLoaded else { return }
        diskCacheLoaded = true
        guard let store else { return }

        let cached = store.load(cacheFile, default: [VideoSummary]())
        lastFeed = cached
        var byChannel: [String: [VideoSummary]] = [:]
        for video in cached {
            if let seconds = video.durationSeconds, seconds > 0 { knownDurations[video.id] = seconds }
            if let channelID = video.channel?.id { byChannel[channelID, default: []].append(video) }
        }
        // Good enough to fall back on when a channel cannot be fetched, never fresh enough to skip a fetch.
        for (channelID, videos) in byChannel where entries[channelID] == nil {
            entries[channelID] = ChannelEntry(videos: videos, fetchedAt: .distantPast)
        }
    }

    private func persist(_ feed: [VideoSummary]) {
        store?.save(feed, to: cacheFile)
    }
}
