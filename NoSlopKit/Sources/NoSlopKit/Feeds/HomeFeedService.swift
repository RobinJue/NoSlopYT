import Foundation
import Synchronization

/// Builds the on-device "For you" feed from watch history, related videos and fresh subscription uploads.
///
/// - **Continue watching**: `HomeFeed.continueWatching(in:)`: history entries that are at least 30 s in, not finished
///   and not Shorts; the 10 most recent, in the order of `history` (most recent first, as `LibraryStore` keeps it).
/// - **For you**: the *seeds* are the most recent distinct non-Short history entries (up to `maxSeeds`). Their watch
///   pages are fetched concurrently (failures and slow answers are skipped) and the first 12 related videos of each are
///   dealt out round-robin, so every seed gets a turn. Videos already in the history, and repeats, are dropped.
///   Uploads from subscriptions that are less than a week old and not in the history take every third slot
///   (indices 2, 5, 8, ...); once one of the two kinds runs out the other fills the remaining slots. At most 60 videos.
/// - Without anything to recommend from (no history, or YouTube cannot be reached) "For you" is simply the latest
///   subscription videos that are not in the history. When the history had videos to ask about and not one of them
///   answered, the feed says so (`HomeFeed.relatedUnavailable`), so that an empty "For you" is not taken for "that is
///   everything".
///
/// The result is not filtered: Shorts, blocked channels and so on are `ContentFilter`'s business.
public actor HomeFeedService: HomeFeedProviding {
    private static let relatedPerSeed = 12
    private static let feedLimit = 60
    private static let freshnessWindow: TimeInterval = 7 * 24 * 60 * 60

    private let youTube: any YouTubeService
    private let maxSeeds: Int
    private let deadline: FetchDeadline
    private let now: @Sendable () -> Date

    public init(youTube: any YouTubeService, maxSeeds: Int = 6) {
        self.init(youTube: youTube, maxSeeds: maxSeeds, fetchTimeout: .seconds(12), now: { Date() })
    }

    /// Tests choose how long to wait for the watch pages and the clock.
    init(youTube: any YouTubeService, maxSeeds: Int, fetchTimeout: Duration, now: @escaping @Sendable () -> Date) {
        self.init(youTube: youTube, maxSeeds: maxSeeds, deadline: .after(fetchTimeout), now: now)
    }

    /// Tests that must not depend on how fast the machine is decide themselves when the time is up.
    init(youTube: any YouTubeService, maxSeeds: Int, deadline: FetchDeadline, now: @escaping @Sendable () -> Date) {
        self.youTube = youTube
        self.maxSeeds = max(0, maxSeeds)
        self.deadline = deadline
        self.now = now
    }

    public func homeFeed(history: [HistoryEntry], subscriptionVideos: [VideoSummary]) async -> HomeFeed {
        let seeds = Self.seedIDs(in: history, limit: maxSeeds)
        let related = await relatedLists(for: seeds)
        let forYou = Self.compose(
            related: related.lists,
            subscriptionVideos: subscriptionVideos,
            historyIDs: Set(history.map(\.id)),
            now: now()
        )
        return HomeFeed(
            continueWatching: HomeFeed.continueWatching(in: history),
            forYou: forYou,
            // Seeds were asked about and none of them answered: YouTube could not be reached. A seed that answered with no
            // related videos at all has answered (YouTube had nothing to suggest, which is a different thing).
            relatedUnavailable: !seeds.isEmpty && related.answered == 0
        )
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

    /// The first related videos of every seed, in the order of the seeds, and how many seeds answered. Seeds that fail
    /// or do not answer within `fetchTimeout` give an empty list and do not count as answered.
    ///
    /// The feed is handed over the moment the last seed has answered or the deadline has passed, whichever comes first,
    /// and a seed that is still busy then is cancelled and left behind. It is not waited for: a structured task group
    /// would wait for its children to finish, which makes the deadline depend on every seed noticing its cancellation
    /// (a request awaiting a shared task does not).
    private func relatedLists(for seedIDs: [String]) async -> RelatedLists {
        guard !seedIDs.isEmpty else { return RelatedLists(lists: [], answered: 0) }
        return await RelatedFetch.run(seedIDs: seedIDs, youTube: youTube, limit: Self.relatedPerSeed, deadline: deadline)
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

// MARK: - Fetching the seeds

/// When a fetch gives up on the seeds that have not answered.
enum FetchDeadline: Sendable {
    /// After this long.
    case after(Duration)
    /// When this returns. Tests use it to decide the moment themselves instead of racing a clock.
    case when(@Sendable () async -> Void)
}

/// What a fetch of the related videos of a few seeds brought: the lists in the order of the seeds, and how many seeds
/// answered (a seed that failed or was given up on has an empty list and did not).
private struct RelatedLists: Sendable {
    var lists: [[VideoSummary]]
    var answered: Int
}

/// One fetch of the related videos of a few seeds, raced against a deadline.
///
/// Every seed is a task of its own, and so is the deadline. The waiting caller is resumed exactly once, by whichever
/// comes first: the last seed answering or the deadline passing. Whatever is still running then (including a seed
/// that does not react to cancellation) is cancelled and left behind: it is not waited for, and what it delivers
/// later is ignored. A caller that is cancelled stops waiting at once.
private final class RelatedFetch: Sendable {
    private struct State {
        var lists: [[VideoSummary]]
        var answered = 0
        var remaining: Int
        var continuation: CheckedContinuation<RelatedLists, Never>?
        /// The seeds and the deadline, to be cancelled when the fetch is over.
        var tasks: [Task<Void, Never>] = []
        var isFinished = false
    }

    /// What has to happen once the fetch is over, done after the lock is released.
    private struct Completion {
        var continuation: CheckedContinuation<RelatedLists, Never>?
        var result: RelatedLists
        var tasks: [Task<Void, Never>]

        func perform() {
            for task in tasks { task.cancel() }
            continuation?.resume(returning: result)
        }
    }

    private let state: Mutex<State>

    private init(seedCount: Int) {
        state = Mutex(State(lists: Array(repeating: [], count: seedCount), remaining: seedCount))
    }

    /// The first `limit` related videos of each seed, in the order of the seeds; empty for a seed that failed or did
    /// not answer before the deadline.
    static func run(
        seedIDs: [String], youTube: any YouTubeService, limit: Int, deadline: FetchDeadline
    ) async -> RelatedLists {
        let fetch = RelatedFetch(seedCount: seedIDs.count)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RelatedLists, Never>) in
                fetch.start(seedIDs: seedIDs, youTube: youTube, limit: limit, deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            // The caller gave up: nobody is waiting for the seeds any more.
            fetch.finish()
        }
    }

    private func start(
        seedIDs: [String], youTube: any YouTubeService, limit: Int, deadline: FetchDeadline,
        continuation: CheckedContinuation<RelatedLists, Never>
    ) {
        // A caller that was cancelled before it got here has nothing to wait for.
        let alreadyFinished = state.withLock { state -> RelatedLists? in
            if state.isFinished { return RelatedLists(lists: state.lists, answered: state.answered) }
            state.continuation = continuation
            return nil
        }
        if let alreadyFinished {
            continuation.resume(returning: alreadyFinished)
            return
        }

        var tasks = seedIDs.enumerated().map { index, id in
            Task {
                let details = try? await youTube.videoDetails(id: id)
                // A failed lookup is not an empty answer: `nil` is told apart from "no related videos".
                self.record(details.map { Array($0.related.prefix(limit)) }, at: index)
            }
        }
        tasks.append(Task {
            switch deadline {
            case .after(let timeout):
                // Cancelled when the fetch is over before the time is up: then there is nothing left to do.
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
            case .when(let timeIsUp):
                await timeIsUp()
            }
            self.finish()
        })

        // Finishing cancels what runs, so it has to know it; when it already happened, cancel it here.
        let finishedMeanwhile = state.withLock { state -> Bool in
            if state.isFinished { return true }
            state.tasks = tasks
            return false
        }
        if finishedMeanwhile {
            for task in tasks { task.cancel() }
        }
    }

    /// `related` is nil for a seed whose watch page could not be loaded.
    private func record(_ related: [VideoSummary]?, at index: Int) {
        let completion = state.withLock { state -> Completion? in
            guard !state.isFinished else { return nil }  // too late: the feed has been handed over
            if let related {
                state.lists[index] = related
                state.answered += 1
            }
            state.remaining -= 1
            return state.remaining == 0 ? Self.complete(&state) : nil
        }
        completion?.perform()
    }

    private func finish() {
        let completion = state.withLock { Self.complete(&$0) }
        completion?.perform()
    }

    /// Marks the fetch over and takes what has to be done about it; nil when it was over already.
    private static func complete(_ state: inout State) -> Completion? {
        guard !state.isFinished else { return nil }
        state.isFinished = true
        let completion = Completion(
            continuation: state.continuation,
            result: RelatedLists(lists: state.lists, answered: state.answered),
            tasks: state.tasks
        )
        state.continuation = nil
        state.tasks = []
        return completion
    }
}
