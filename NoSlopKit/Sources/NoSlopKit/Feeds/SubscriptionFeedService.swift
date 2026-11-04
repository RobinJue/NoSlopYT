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
/// - A refresh is shared. Home and Subscriptions both ask for the feed, often at the same moment, and asking twice
///   would crawl every channel twice. A call that comes while a refresh is running which covers its channels waits for
///   that refresh instead of starting another: the same channels, or fewer. A forced call needs more than that, as
///   `forceRefresh` means "ask again": the refresh must ask for each of its channels itself, not have left one out
///   because it was fetched a few minutes ago. A call for channels the running refresh does not cover starts a refresh
///   of its own. The refresh belongs to nobody who asks: a call that is cancelled stops waiting at once and leaves
///   the refresh to the others, and the refresh is cancelled only when the last of them has gone. The 15 seconds
///   count from the start of the refresh, so whoever joins late waits for what is left.
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

    /// The refreshes that are running, the oldest first.
    private var running: [SharedRefresh] = []
    /// How many refreshes were started, and how many calls waited for one that was running instead. The tests read
    /// them to know that a call has found its refresh.
    private(set) var refreshesStarted = 0
    private(set) var callsJoined = 0

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

        let (refresh, ticket) = try await joinOrStartRefresh(for: channels, ids: seenIDs, forced: forceRefresh)
        // A caller that is cancelled stops waiting at once. The refresh goes on for whoever else waits for it, and is
        // cancelled when nobody does.
        guard let outcome = await refresh.wait(ticket), !Task.isCancelled else { throw NoSlopError.cancelled }
        if let failure = outcome.failure(for: channels) { throw failure }
        return assembledFeed(for: channels)
    }

    // MARK: Sharing a refresh

    /// The refresh that serves a call for `channels`: one that is running and covers them (the call waits for it), or a
    /// new one.
    private func joinOrStartRefresh(
        for channels: [SubscribedChannel], ids: Set<String>, forced: Bool
    ) async throws -> (SharedRefresh, SharedRefresh.Ticket) {
        while true {
            if let refresh = running.first(where: { $0.canServe(ids, forced: forced) }), let ticket = refresh.join() {
                callsJoined += 1
                return (refresh, ticket)
            }
            // A refresh that everybody has left is cancelled and about to end. What it had fetched is recorded when it
            // is over, and the new refresh starts from there instead of asking for the same channels again.
            guard let winding = running.first(where: { $0.isAbandoned && $0.overlaps(ids) }) else { break }
            await winding.windUp()
            if Task.isCancelled { throw NoSlopError.cancelled }
        }
        return startRefresh(of: channels, ids: ids, forced: forced)
    }

    private func startRefresh(
        of channels: [SubscribedChannel], ids: Set<String>, forced: Bool
    ) -> (SharedRefresh, SharedRefresh.Ticket) {
        let startedAt = now()
        let due = fetchOrder(channels.filter { isDue($0, forced: forced, at: startedAt) })
        let refresh = SharedRefresh(channelIDs: ids, fetchingIDs: Set(due.map(\.id)))
        running.append(refresh)
        refreshesStarted += 1
        refresh.begin(Task { await self.perform(refresh, for: channels, fetching: due, startedAt: startedAt) })
        return (refresh, SharedRefresh.starterTicket)
    }

    /// Whether the channel has to be asked for: always on a forced refresh; otherwise when it was not fetched in this
    /// session (a copy from the disk cache has no fetch time) or was fetched longer ago than the cache lifetime.
    private func isDue(_ channel: SubscribedChannel, forced: Bool, at startedAt: Date) -> Bool {
        guard !forced, let entry = entries[channel.id], entry.fetchedAt != .distantPast else { return true }
        return startedAt.timeIntervalSince(entry.fetchedAt) >= channelCacheTTL
    }

    /// The refresh itself. It runs as a task of its own, which belongs to nobody who asked: it keeps going when one of
    /// them is cancelled, and ends when the last of them has gone. `outcome` is handed to everybody who waits.
    private func perform(
        _ refresh: SharedRefresh, for channels: [SubscribedChannel], fetching toFetch: [SubscribedChannel], startedAt: Date
    ) async {
        var outcome = RefreshOutcome()
        defer {
            running.removeAll { $0 === refresh }
            refresh.finish(outcome)
        }

        let clock = ContinuousClock()
        let started = clock.now
        let results = await fetch(toFetch)

        // What arrived is kept, also when everyone who asked has gone away or the others did not answer in time: the
        // next refresh does not ask for it again.
        var timedOut = false
        for (channel, result) in zip(toFetch, results) {
            switch result {
            case .success(let videos)?:
                entries[channel.id] = ChannelEntry(videos: Self.attributed(videos, to: channel), fetchedAt: startedAt)
            case .failure(let error)?:
                outcome.errors[channel.id] = error
            case nil:
                outcome.unanswered.insert(channel.id)
                timedOut = true
            }
        }
        // Everyone who asked has gone away: keep what is cached and do not publish half a refresh. And when every
        // channel failed there is no feed to publish: the cached one stays as it was.
        if Task.isCancelled || outcome.failure(for: channels) != nil { return }

        let merged = Self.sortedUnique(channels.flatMap { entries[$0.id]?.videos ?? [] })
        // The channels that did not answer used up the time; otherwise the durations get what is left of it.
        let remaining = timedOut ? nil : fetchDeadline.reduced(by: started.duration(to: clock.now))
        let feed = await fillingDurations(in: merged, deadline: remaining)
        if Task.isCancelled { return }
        lastFeed = feed
        persist(feed)
    }

    /// The merged feed of `channels` as the service holds it now, with the durations it knows. Nothing is fetched.
    private func assembledFeed(for channels: [SubscribedChannel]) -> [VideoSummary] {
        applyingKnownDurations(to: Self.sortedUnique(channels.flatMap { entries[$0.id]?.videos ?? [] }))
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
        let videos = applyingKnownDurations(to: videos)
        let missing = videos.filter { $0.durationSeconds == nil }.map(\.id)
        guard let account, let deadline, !missing.isEmpty else { return videos }

        for (id, seconds) in await lookUpDurations(of: missing, with: account, deadline: deadline) {
            knownDurations[id] = seconds
        }
        return applyingKnownDurations(to: videos)
    }

    /// `videos` with the durations that were learned before filled in where a video has none.
    private func applyingKnownDurations(to videos: [VideoSummary]) -> [VideoSummary] {
        var videos = videos
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

// MARK: - A refresh that several calls wait for

/// What a refresh found out, handed to everybody who waited for it.
private struct RefreshOutcome: Sendable {
    /// The channels that answered with an error, and the error.
    var errors: [String: any Error] = [:]
    /// The channels that had not answered when the time was up.
    var unanswered: Set<String> = []

    /// Why `channels` have no feed: only when every one of them failed, and then the error of the first that has one
    /// (a channel that did not answer has none to give; when none has, the time-out). nil when at least one channel is
    /// there, which is also when it was merely left out as fresh.
    func failure(for channels: [SubscribedChannel]) -> (any Error)? {
        guard !channels.isEmpty, channels.allSatisfy({ errors[$0.id] != nil || unanswered.contains($0.id) }) else { return nil }
        return channels.lazy.compactMap { errors[$0.id] }.first
            ?? NoSlopError.network("The channels did not answer within \(SubscriptionFeedService.refreshTimeLimit).")
    }
}

/// One refresh of a set of channels, running as a task of its own, and the calls that wait for it.
///
/// Every call holds a ticket. The call that starts the refresh has the first one, a call that joins gets the next. A
/// call that is cancelled hands its ticket back and stops waiting at once; the refresh goes on for the others. When
/// the last ticket is gone nobody needs the refresh any more: it is given up and its task cancelled, which ends it
/// soon (see `windUp`).
private final class SharedRefresh: Sendable {
    typealias Ticket = Int

    static let starterTicket: Ticket = 0

    /// The channels the refresh was started for, and those it asks YouTube for; the others were fresh already.
    let channelIDs: Set<String>
    let fetchingIDs: Set<String>

    private struct State: Sendable {
        var outcome: RefreshOutcome?
        var work: Task<Void, Never>?
        var isAbandoned = false
        var nextTicket = SharedRefresh.starterTicket + 1
        /// The calls that wait for the outcome or are about to: they have a ticket, but not necessarily a continuation.
        var holders: Set<Ticket> = [SharedRefresh.starterTicket]
        var continuations: [Ticket: CheckedContinuation<RefreshOutcome?, Never>] = [:]
        /// Tickets that were handed back before their holder began to wait.
        var returned: Set<Ticket> = []
    }

    private enum Registration {
        case waiting
        case answered(RefreshOutcome)
        case returned
    }

    private let state = Mutex(State())

    init(channelIDs: Set<String>, fetchingIDs: Set<String>) {
        self.channelIDs = channelIDs
        self.fetchingIDs = fetchingIDs
    }

    /// Whether a call for `ids` can wait for this refresh: it is running and has not been given up, and it covers
    /// `ids`. A forced call needs each of them to be asked for by this refresh itself; one that was left out as fresh
    /// may be fifteen minutes old, which is what forcing a refresh is not supposed to settle for.
    func canServe(_ ids: Set<String>, forced: Bool) -> Bool {
        guard (forced ? fetchingIDs : channelIDs).isSuperset(of: ids) else { return false }
        return state.withLock { $0.outcome == nil && !$0.isAbandoned }
    }

    func overlaps(_ ids: Set<String>) -> Bool {
        !channelIDs.isDisjoint(with: ids)
    }

    /// Everybody has left: the refresh was cancelled and nobody can join it any more.
    var isAbandoned: Bool {
        state.withLock { $0.isAbandoned }
    }

    /// Hands over the task that does the work, started by the call that made this refresh.
    func begin(_ work: Task<Void, Never>) {
        let isGivenUp = state.withLock { state -> Bool in
            guard state.outcome == nil else { return false }
            state.work = work
            return state.isAbandoned
        }
        if isGivenUp { work.cancel() }
    }

    /// A ticket for a call that waits for this refresh; nil when it is over or has been given up. A call has to take
    /// its ticket in the same step in which it decides to join, so that the refresh cannot be given up in between.
    func join() -> Ticket? {
        state.withLock { state -> Ticket? in
            guard state.outcome == nil, !state.isAbandoned else { return nil }
            let ticket = state.nextTicket
            state.nextTicket += 1
            state.holders.insert(ticket)
            return ticket
        }
    }

    /// Suspends until the refresh is over. nil when the call is cancelled first: it gives its ticket back and is
    /// resumed at once.
    func wait(_ ticket: Ticket) async -> RefreshOutcome? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RefreshOutcome?, Never>) in
                let registration = state.withLock { state -> Registration in
                    // Cancelled before it got here (also when the task was cancelled to begin with).
                    if state.returned.contains(ticket) { return .returned }
                    if let outcome = state.outcome { return .answered(outcome) }
                    state.continuations[ticket] = continuation
                    return .waiting
                }
                switch registration {
                case .waiting: break
                case .answered(let outcome): continuation.resume(returning: outcome)
                case .returned: continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            giveBack(ticket)
        }
    }

    private func giveBack(_ ticket: Ticket) {
        let (continuation, work) = state.withLock { state -> (CheckedContinuation<RefreshOutcome?, Never>?, Task<Void, Never>?) in
            // Answered already: the call gets the outcome, and there is nothing to hand back.
            guard state.outcome == nil else { return (nil, nil) }
            state.returned.insert(ticket)
            state.holders.remove(ticket)
            let continuation = state.continuations.removeValue(forKey: ticket)
            guard state.holders.isEmpty else { return (continuation, nil) }
            state.isAbandoned = true
            return (continuation, state.work)
        }
        continuation?.resume(returning: nil)
        work?.cancel()
    }

    /// The work is done: everybody who waits gets the outcome.
    func finish(_ outcome: RefreshOutcome) {
        let waiting = state.withLock { state -> [CheckedContinuation<RefreshOutcome?, Never>] in
            guard state.outcome == nil else { return [] }
            state.outcome = outcome
            state.work = nil
            state.holders = []
            defer { state.continuations = [:] }
            return Array(state.continuations.values)
        }
        for continuation in waiting { continuation.resume(returning: outcome) }
    }

    /// Suspends until the work has ended. For a refresh that was given up that is soon: the requests it has running are
    /// cancelled, and it records what it had got before it ends.
    func windUp() async {
        let work = state.withLock { $0.work }
        await work?.value
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
