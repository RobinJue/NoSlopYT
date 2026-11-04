import Foundation
import Synchronization

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
/// - A refresh takes 15 seconds at the most, all in all (`refreshTimeLimit`). A few hundred subscriptions on a weak
///   connection, or a connection that is up but stalled, would otherwise keep Home and Subscriptions on their
///   skeletons for minutes. When the time is up no new request is started, the ones still running are cancelled, what
///   had arrived is kept, and the channels that had not answered count as failed for this refresh: they keep the
///   videos they had, and the next refresh asks for them first. If not one channel answered, the first error (or a
///   time-out) is thrown, as when every channel fails. The durations lookup gets what is left of the time, and none
///   when the channels used it all.
/// - After every refresh that produced a feed it is written to `cacheURL`, and `cachedFeed()` serves it for an
///   instant first paint on the next launch.
public actor SubscriptionFeedService: SubscriptionFeedProviding {
    private struct ChannelEntry {
        var videos: [VideoSummary]
        var fetchedAt: Date
    }

    private static let durationBatchSize = 50

    /// How long a refresh may take in all, from the first request to the last duration looked up.
    static let refreshTimeLimit: Duration = .seconds(15)

    private let rss: any RSSFeedFetching
    private let account: (any YouTubeAccountService)?
    private let store: JSONFileStore?
    private let cacheFile: String
    private let maxConcurrent: Int
    private let channelCacheTTL: TimeInterval
    private let fetchDeadline: FetchDeadline
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
            channelCacheTTL: 15 * 60, fetchDeadline: .after(Self.refreshTimeLimit), now: { Date() }
        )
    }

    /// Tests choose the per-channel cache lifetime, when the refresh gives up and the clock.
    init(
        rss: any RSSFeedFetching,
        account: (any YouTubeAccountService)?,
        cacheURL: URL?,
        maxConcurrent: Int,
        channelCacheTTL: TimeInterval,
        fetchDeadline: FetchDeadline = .after(SubscriptionFeedService.refreshTimeLimit),
        now: @escaping @Sendable () -> Date
    ) {
        self.rss = rss
        self.account = account
        self.store = cacheURL.map { JSONFileStore(directory: $0.deletingLastPathComponent()) }
        self.cacheFile = cacheURL?.lastPathComponent ?? ""
        self.maxConcurrent = max(1, maxConcurrent)
        self.channelCacheTTL = channelCacheTTL
        self.fetchDeadline = fetchDeadline
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
        let clock = ContinuousClock()
        let started = clock.now
        let toFetch = fetchOrder(channels.filter { channel in
            guard !forceRefresh, let entry = entries[channel.id], entry.fetchedAt != .distantPast else { return true }
            return startedAt.timeIntervalSince(entry.fetchedAt) >= channelCacheTTL
        })
        let outcomes = await fetch(toFetch)

        // What arrived is kept, also when whoever asked has gone away or the others did not answer in time: the next
        // refresh does not ask for it again.
        var errors: [String: any Error] = [:]
        var failures = 0
        var timedOut = false
        for (channel, outcome) in zip(toFetch, outcomes) {
            switch outcome {
            case .success(let videos)?:
                entries[channel.id] = ChannelEntry(videos: Self.attributed(videos, to: channel), fetchedAt: startedAt)
            case .failure(let error)?:
                failures += 1
                errors[channel.id] = error
            case nil:
                failures += 1
                timedOut = true
            }
        }
        // Whoever asked has gone away: keep what is cached and do not publish half a refresh.
        if Task.isCancelled { throw NoSlopError.cancelled }
        if failures == channels.count {
            // The error of the first channel that has one; a channel that did not answer has none to give.
            throw channels.lazy.compactMap { errors[$0.id] }.first
                ?? NoSlopError.network("The channels did not answer within \(Self.refreshTimeLimit).")
        }

        let merged = Self.sortedUnique(channels.flatMap { entries[$0.id]?.videos ?? [] })
        // The channels that did not answer used up the time; otherwise the durations get what is left of it.
        let remaining = timedOut ? nil : fetchDeadline.reduced(by: started.duration(to: clock.now))
        let feed = await fillingDurations(in: merged, deadline: remaining)
        lastFeed = feed
        persist(feed)
        return feed
    }

    // MARK: Fetching

    private typealias ChannelOutcome = Result<[VideoSummary], any Error>

    /// The channels with no videos yet (never fetched, or only known from the disk cache) first, then those that were
    /// fetched the longest ago; channels that are equally old keep their order. A refresh that is cut short by the
    /// deadline therefore continues where the last one stopped, instead of asking the same first channels again and
    /// again while the ones at the end of the list are never reached (pull to refresh asks for every channel).
    private func fetchOrder(_ channels: [SubscribedChannel]) -> [SubscribedChannel] {
        channels.enumerated().sorted { lhs, rhs in
            let left = entries[lhs.element.id]?.fetchedAt ?? .distantPast
            let right = entries[rhs.element.id]?.fetchedAt ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// The RSS videos of `channels`, in the same order, nil for a channel that did not answer before the deadline; at
    /// most `maxConcurrent` requests run at a time.
    private func fetch(_ channels: [SubscribedChannel]) async -> [ChannelOutcome?] {
        let rss = rss
        return await DeadlineFanOut<ChannelOutcome>.run(count: channels.count, limit: maxConcurrent, deadline: fetchDeadline) { index in
            do {
                return .success(try await rss.latestVideos(channelID: channels[index].id))
            } catch {
                return .failure(error)
            }
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

    /// - Parameter deadline: how long the lookup may take; nil when the time is up already (the durations that are
    ///   known are filled in, nothing is asked).
    private func fillingDurations(in videos: [VideoSummary], deadline: FetchDeadline?) async -> [VideoSummary] {
        var videos = videos
        var missing: [String] = []
        for index in videos.indices where videos[index].durationSeconds == nil {
            if let known = knownDurations[videos[index].id] {
                videos[index].durationSeconds = known
            } else {
                missing.append(videos[index].id)
            }
        }
        guard let account, let deadline, !missing.isEmpty else { return videos }

        for (id, seconds) in await lookUpDurations(of: missing, with: account, deadline: deadline) {
            knownDurations[id] = seconds
        }
        for index in videos.indices where videos[index].durationSeconds == nil {
            videos[index].durationSeconds = knownDurations[videos[index].id]
        }
        return videos
    }

    /// Video id -> seconds for the ids the account's Data API knows. Any failure just means fewer durations, and so
    /// does the deadline: a lookup that is not finished by then is cancelled and its batches count as failed.
    private func lookUpDurations(
        of ids: [String], with account: any YouTubeAccountService, deadline: FetchDeadline
    ) async -> [String: Int] {
        let batches = stride(from: 0, to: ids.count, by: Self.durationBatchSize).map { start in
            Array(ids[start..<min(start + Self.durationBatchSize, ids.count)])
        }
        let clock = ContinuousClock()
        let started = clock.now
        // The first batch goes alone: when the account is signed out (or out of quota) the rest would fail the same way.
        let first = await DeadlineFanOut<[String: Int]?>.run(count: 1, limit: 1, deadline: deadline) { _ in
            try? await account.durations(videoIDs: batches[0])
        }
        guard var found = first[0] ?? nil else { return [:] }

        let others = await DeadlineFanOut<[String: Int]>.run(
            count: batches.count - 1, limit: maxConcurrent, deadline: deadline.reduced(by: started.duration(to: clock.now))
        ) { index in
            (try? await account.durations(videoIDs: batches[index + 1])) ?? [:]
        }
        for case let batchResult? in others {
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

// MARK: - Requests against a deadline

extension FetchDeadline {
    /// What is left of this deadline `elapsed` after it started. A gate has no length of time: it stays as it is.
    func reduced(by elapsed: Duration) -> FetchDeadline {
        switch self {
        case .after(let length): .after(max(.zero, length - elapsed))
        case .when: self
        }
    }

    /// A deadline with no time left: nothing is started under it.
    fileprivate var isExhausted: Bool {
        if case .after(let length) = self { return length <= .zero }
        return false
    }
}

/// `work(0)`, `work(1)`, ... `work(count - 1)`, at most `limit` at a time, raced against a deadline.
///
/// Every piece of work is a task of its own, and so is the deadline. The waiting caller is resumed exactly once, by
/// whichever comes first: the last piece of work finishing or the deadline passing. After that no further piece is
/// started, and whatever is still running is cancelled and left behind: it is not waited for, and what it delivers
/// later is ignored. (A task group would wait for its children, which makes the deadline depend on every request
/// noticing its cancellation, as `HomeFeedService`'s `RelatedFetch` explains.) A caller that is cancelled stops
/// waiting at once, with what had arrived.
private final class DeadlineFanOut<Output: Sendable>: Sendable {
    private struct State {
        var outputs: [Output?]
        var nextIndex = 0
        var remaining: Int
        var continuation: CheckedContinuation<[Output?], Never>?
        /// The workers and the timer, to be cancelled when the fan-out is over.
        var tasks: [Task<Void, Never>] = []
        var isFinished = false
    }

    /// What has to happen once the fan-out is over, done after the lock is released.
    private struct Completion {
        var continuation: CheckedContinuation<[Output?], Never>?
        var outputs: [Output?]
        var tasks: [Task<Void, Never>]

        func perform() {
            for task in tasks { task.cancel() }
            continuation?.resume(returning: outputs)
        }
    }

    private let state: Mutex<State>
    private let work: @Sendable (Int) async -> Output

    private init(count: Int, work: @escaping @Sendable (Int) async -> Output) {
        state = Mutex(State(outputs: Array(repeating: nil, count: count), remaining: count))
        self.work = work
    }

    /// The outputs in the order of the work: nil where the work had not finished when the deadline passed (or the
    /// caller was cancelled), and for all of it when the deadline had no time left to begin with.
    static func run(
        count: Int, limit: Int, deadline: FetchDeadline, _ work: @escaping @Sendable (Int) async -> Output
    ) async -> [Output?] {
        guard count > 0 else { return [] }
        guard !deadline.isExhausted else { return Array(repeating: nil, count: count) }
        let fanOut = DeadlineFanOut(count: count, work: work)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[Output?], Never>) in
                fanOut.start(slots: max(1, min(limit, count)), deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            // The caller gave up: nobody is waiting for the work any more.
            fanOut.finish()
        }
    }

    private func start(slots: Int, deadline: FetchDeadline, continuation: CheckedContinuation<[Output?], Never>) {
        // A caller that was cancelled before it got here has nothing to wait for.
        let alreadyFinished = state.withLock { state -> [Output?]? in
            if state.isFinished { return state.outputs }
            state.continuation = continuation
            return nil
        }
        if let alreadyFinished {
            continuation.resume(returning: alreadyFinished)
            return
        }

        for _ in 0..<slots { launchNext() }
        adopt(Task {
            switch deadline {
            case .after(let length):
                // Cancelled when the work is over before the time is up: then there is nothing left to do.
                guard (try? await Task.sleep(for: length)) != nil else { return }
            case .when(let timeIsUp):
                await timeIsUp()
            }
            self.finish()
        })
    }

    /// Starts the next piece of work, if there is any left and the fan-out is still on.
    private func launchNext() {
        let index = state.withLock { state -> Int? in
            guard !state.isFinished, state.nextIndex < state.outputs.count else { return nil }
            defer { state.nextIndex += 1 }
            return state.nextIndex
        }
        guard let index else { return }
        adopt(Task {
            let output = await self.work(index)
            self.record(output, at: index)
        })
    }

    /// Finishing cancels what runs, so it has to know it; a task that arrives when it is over is cancelled here.
    private func adopt(_ task: Task<Void, Never>) {
        let isOver = state.withLock { state -> Bool in
            if state.isFinished { return true }
            state.tasks.append(task)
            return false
        }
        if isOver { task.cancel() }
    }

    private func record(_ output: Output, at index: Int) {
        let completion = state.withLock { state -> Completion? in
            guard !state.isFinished else { return nil }  // too late: the outputs have been handed over
            state.outputs[index] = output
            state.remaining -= 1
            return state.remaining == 0 ? Self.complete(&state) : nil
        }
        if let completion {
            completion.perform()
        } else {
            launchNext()
        }
    }

    private func finish() {
        let completion = state.withLock { Self.complete(&$0) }
        completion?.perform()
    }

    /// Marks the fan-out over and takes what has to be done about it; nil when it was over already.
    private static func complete(_ state: inout State) -> Completion? {
        guard !state.isFinished else { return nil }
        state.isFinished = true
        let completion = Completion(continuation: state.continuation, outputs: state.outputs, tasks: state.tasks)
        state.continuation = nil
        state.tasks = []
        return completion
    }
}
