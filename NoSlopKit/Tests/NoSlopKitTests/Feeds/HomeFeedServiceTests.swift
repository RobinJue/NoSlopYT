import Foundation
import Testing
@testable import NoSlopKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func makeVideo(
    _ id: String,
    daysAgo: Double? = nil,
    isShort: Bool = false
) -> VideoSummary {
    VideoSummary(
        id: id,
        title: "Video \(id)",
        channel: ChannelRef(id: "UC_\(id)", name: "Channel \(id)"),
        publishedAt: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
        isShort: isShort
    )
}

private func makeEntry(
    _ id: String,
    progress: Double = 100,
    duration: Double? = 600,
    isShort: Bool = false
) -> HistoryEntry {
    HistoryEntry(
        video: makeVideo(id, isShort: isShort),
        lastWatchedAt: now,
        progressSeconds: progress,
        durationSeconds: duration
    )
}

/// Suspends whoever waits for it until it is opened. Unlike `Task.sleep` it takes no notice of cancellation, which is
/// how a request that is waiting for something shared (a visitor token being fetched) behaves.
private final class UncancellableGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in continuations { continuation.resume() }
    }
}

/// A `YouTubeService` that only knows watch pages: `related` lists the related videos of each seed.
private actor RelatedSource: YouTubeService {
    private let related: [String: [VideoSummary]]
    private let failing: Set<String>
    private let hanging: Set<String>
    private let stuck: Set<String>
    private let gate: UncancellableGate
    private let rendezvous: Int?
    private let delay: Duration
    private(set) var requested: [String] = []
    /// The seeds that were cancelled while they hung, and the ones that ran to the end.
    private(set) var cancelled: [String] = []
    private(set) var finished: [String] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    /// `hanging` seeds sleep for an hour but notice cancellation; `stuck` seeds wait for `gate` and do not. With
    /// `rendezvous`, no seed answers before that many are in flight at once (a test of concurrency that needs no
    /// timing: sequential fetching would never get there).
    init(
        related: [String: [VideoSummary]] = [:],
        failing: Set<String> = [],
        hanging: Set<String> = [],
        stuck: Set<String> = [],
        gate: UncancellableGate = UncancellableGate(),
        rendezvous: Int? = nil,
        delay: Duration = .zero
    ) {
        self.related = related
        self.failing = failing
        self.hanging = hanging
        self.stuck = stuck
        self.gate = gate
        self.rendezvous = rendezvous
        self.delay = delay
    }

    func videoDetails(id: String) async throws -> VideoDetails {
        requested.append(id)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer {
            inFlight -= 1
            finished.append(id)
        }
        if hanging.contains(id) {
            do { try await Task.sleep(for: .seconds(3_600)) } catch {
                cancelled.append(id)
                throw NoSlopError.cancelled
            }
        }
        if stuck.contains(id) { await gate.wait() }
        if let rendezvous {
            if inFlight >= rendezvous { gate.open() }
            await gate.wait()
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        if failing.contains(id) { throw NoSlopError.network("down") }
        return VideoDetails(id: id, title: "Seed \(id)", channel: ChannelRef(id: "UC_seed", name: "Seed"), related: related[id] ?? [])
    }

    func search(query: String, filter: SearchFilter) async throws -> Page<SearchItem> { throw NoSlopError.notImplemented("RelatedSource.search") }
    func searchMore(continuation: String) async throws -> Page<SearchItem> { throw NoSlopError.notImplemented("RelatedSource.searchMore") }
    func suggestions(for query: String) async throws -> [String] { throw NoSlopError.notImplemented("RelatedSource.suggestions") }
    func moreRelated(continuation: String) async throws -> Page<VideoSummary> { throw NoSlopError.notImplemented("RelatedSource.moreRelated") }
    func comments(continuation: String) async throws -> CommentsPage { throw NoSlopError.notImplemented("RelatedSource.comments") }
    func channel(id: String) async throws -> ChannelPage { throw NoSlopError.notImplemented("RelatedSource.channel") }
    func channelTab(channelID: String, tab: ChannelTabKind) async throws -> Page<SearchItem> {
        throw NoSlopError.notImplemented("RelatedSource.channelTab")
    }
    func channelMore(continuation: String) async throws -> Page<SearchItem> { throw NoSlopError.notImplemented("RelatedSource.channelMore") }
    func playlist(id: String) async throws -> PlaylistPage { throw NoSlopError.notImplemented("RelatedSource.playlist") }
    func playlistMore(continuation: String) async throws -> Page<VideoSummary> { throw NoSlopError.notImplemented("RelatedSource.playlistMore") }
    func resolve(url: URL) async throws -> ResolvedURL? { throw NoSlopError.notImplemented("RelatedSource.resolve") }
}

/// Polls `condition` every 5 ms until it holds (true) or ten seconds have passed (false).
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func makeService(_ source: RelatedSource, maxSeeds: Int = 6, timeout: Duration = .seconds(10)) -> HomeFeedService {
    HomeFeedService(youTube: source, maxSeeds: maxSeeds, fetchTimeout: timeout, now: { now })
}

/// A service whose deadline passes when the test opens `timeIsUp`, however fast or slow the machine is.
private func makeService(_ source: RelatedSource, timeIsUp: UncancellableGate) -> HomeFeedService {
    HomeFeedService(youTube: source, maxSeeds: 6, deadline: .when { await timeIsUp.wait() }, now: { now })
}

/// Lets everything that is ready to run (a seed that has just answered still has to hand its answer over) run first.
private func settle() async {
    for _ in 0..<50 { await Task.yield() }
}

@Suite struct HomeFeedServiceTests {
    // MARK: From the plan

    @Test func interleavesRelatedOfRecentHistory() async {
        let source = RelatedSource(related: [
            "h1": [makeVideo("a"), makeVideo("b")],
            "h2": [makeVideo("c"), makeVideo("d")],
            "h3": [makeVideo("e")],
        ])
        let service = makeService(source)

        let feed = await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2"), makeEntry("h3")], subscriptionVideos: [])

        #expect(feed.forYou.map(\.id) == ["a", "c", "e", "b", "d"])
    }

    @Test func excludesHistoryAndDuplicates() async {
        let source = RelatedSource(related: [
            "h1": [makeVideo("h2"), makeVideo("a"), makeVideo("a"), makeVideo("h1")],
            "h2": [makeVideo("a"), makeVideo("b"), makeVideo("h1")],
        ])
        let service = makeService(source)

        let feed = await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2"), makeEntry("old", progress: 3)], subscriptionVideos: [])

        // The seeds themselves and anything else in the history are never suggested; "a" only once.
        #expect(feed.forYou.map(\.id) == ["a", "b"])
    }

    @Test func insertsFreshSubscriptionVideosEveryThirdSlot() async {
        let related = (1...8).map { makeVideo("r\($0)") }
        let source = RelatedSource(related: ["h1": related])
        let service = makeService(source)
        let subscriptions = [
            makeVideo("s-fresh-1", daysAgo: 0.5),
            makeVideo("s-fresh-2", daysAgo: 3),
            makeVideo("s-stale", daysAgo: 8),
            makeVideo("s-watched", daysAgo: 1),
            makeVideo("s-fresh-3", daysAgo: 6.9),
            makeVideo("s-undated"),
        ]
        let history = [makeEntry("h1"), makeEntry("s-watched")]

        let feed = await service.homeFeed(history: history, subscriptionVideos: subscriptions)

        let ids = feed.forYou.map(\.id)
        #expect(ids == ["r1", "r2", "s-fresh-1", "r3", "r4", "s-fresh-2", "r5", "r6", "s-fresh-3", "r7", "r8"])
        // Subscription uploads sit at the indices 2, 5, 8.
        #expect(ids.enumerated().filter { $0.element.hasPrefix("s-") }.map(\.offset) == [2, 5, 8])
    }

    @Test func continueWatchingRules() async {
        let source = RelatedSource()
        let service = makeService(source)
        var history: [HistoryEntry] = [
            makeEntry("too-short", progress: 29.9),
            makeEntry("exactly-30", progress: 30),
            makeEntry("finished", progress: 595, duration: 600),
            makeEntry("short-video", progress: 100, isShort: true),
            makeEntry("unknown-duration", progress: 500, duration: nil),
        ]
        history += (1...12).map { makeEntry("keep-\($0)", progress: 60 + Double($0)) }

        let feed = await service.homeFeed(history: history, subscriptionVideos: [])

        // Unfinished, not a Short, at least 30 s in; the most recent ten, in history order.
        #expect(feed.continueWatching.map(\.id) == ["exactly-30", "unknown-duration"] + (1...8).map { "keep-\($0)" })
        #expect(feed.continueWatching.count == 10)
    }

    @Test func emptyHistoryUsesSubscriptions() async {
        let source = RelatedSource()
        let service = makeService(source)
        let subscriptions = (0..<80).map { makeVideo("s\($0)", daysAgo: Double($0)) }

        let feed = await service.homeFeed(history: [], subscriptionVideos: subscriptions)

        #expect(feed.forYou == Array(subscriptions.prefix(60)))
        #expect(feed.continueWatching.isEmpty)
        #expect(await source.requested.isEmpty, "no history means nothing to ask YouTube about")
    }

    // MARK: Seeds

    @Test func seedsAreTheMostRecentDistinctNonShortHistoryEntries() async {
        let source = RelatedSource()
        let service = makeService(source, maxSeeds: 3)
        let history = [
            makeEntry("h1", isShort: true), makeEntry("h2"), makeEntry("h2"), makeEntry("h3"), makeEntry("h4"), makeEntry("h5"),
        ]

        _ = await service.homeFeed(history: history, subscriptionVideos: [])

        #expect(await source.requested.sorted() == ["h2", "h3", "h4"])
    }

    @Test func theDefaultIsSixSeedsAndTwelveRelatedVideosEach() async {
        let source = RelatedSource(related: ["h1": (1...30).map { makeVideo("r\($0)") }])
        let service = HomeFeedService(youTube: source)

        let feed = await service.homeFeed(history: (1...9).map { makeEntry("h\($0)") }, subscriptionVideos: [])

        #expect(await source.requested.count == 6)
        #expect(feed.forYou.map(\.id) == (1...12).map { "r\($0)" })
    }

    @Test func noSeedsAreRequestedForAnEmptyBudget() async {
        let source = RelatedSource(related: ["h1": [makeVideo("a")]])
        let service = makeService(source, maxSeeds: 0)
        let subscriptions = [makeVideo("s1", daysAgo: 20)]

        let feed = await service.homeFeed(history: [makeEntry("h1")], subscriptionVideos: subscriptions)

        #expect(await source.requested.isEmpty)
        #expect(feed.forYou.map(\.id) == ["s1"])
    }

    @Test(.timeLimit(.minutes(1)))
    func seedsAreFetchedConcurrently() async {
        // No seed answers before all five are in flight, so a service that asked one after the other would wait for
        // ever (until the time limit) instead of passing by luck of timing.
        let source = RelatedSource(related: [:], rendezvous: 5)
        let service = makeService(source)

        _ = await service.homeFeed(history: (1...5).map { makeEntry("h\($0)") }, subscriptionVideos: [])

        #expect(await source.maxInFlight == 5)
    }

    @Test func failingSeedsAreIgnored() async {
        let source = RelatedSource(related: ["h2": [makeVideo("c"), makeVideo("d")]], failing: ["h1", "h3"])
        let service = makeService(source)

        let feed = await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2"), makeEntry("h3")], subscriptionVideos: [])

        #expect(feed.forYou.map(\.id) == ["c", "d"])
    }

    // MARK: The deadline
    //
    // What these tests prove is that the feed is not held back by a seed that never answers, not how fast the machine
    // is: a test run executes hundreds of tests at once, often next to other builds. So only one test races the real
    // clock, and it has a seed that never answers and nothing else to lose (its bounds are generous). The tests that are
    // about which answers made it use a deadline that the test itself lets pass once the others have answered.
    // A regression (waiting for the hanging seed) takes an hour, which the time limit turns into a failure after a minute.

    @Test(.timeLimit(.minutes(1)))
    func aSeedThatNeverAnswersDoesNotHoldTheFeedBack() async {
        let source = RelatedSource(hanging: ["h1"])
        let service = makeService(source, timeout: .milliseconds(100))
        let subscriptions = [makeVideo("s1", daysAgo: 30)]

        let started = ContinuousClock.now
        let feed = await service.homeFeed(history: [makeEntry("h1")], subscriptionVideos: subscriptions)
        let elapsed = ContinuousClock.now - started

        // Nothing was learned about the seed, so "For you" is what it is without one: the subscriptions.
        #expect(feed.forYou.map(\.id) == ["s1"])
        #expect(elapsed < .seconds(30))
        // The seed that was given up on is cancelled rather than left running.
        #expect(await eventually { await source.cancelled == ["h1"] })
    }

    @Test(.timeLimit(.minutes(1)))
    func theAnswersThatCameInTimeAreKeptWhenAnotherSeedNeverAnswers() async {
        let source = RelatedSource(related: ["h2": [makeVideo("c")]], hanging: ["h1"])
        let timeIsUp = UncancellableGate()
        let service = makeService(source, timeIsUp: timeIsUp)

        let call = Task { await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2")], subscriptionVideos: []) }
        #expect(await eventually { await source.finished == ["h2"] })
        await settle()
        timeIsUp.open()
        let feed = await call.value

        #expect(feed.forYou.map(\.id) == ["c"])
        #expect(await eventually { await source.cancelled == ["h1"] })
    }

    @Test(.timeLimit(.minutes(1)))
    func aSeedThatIgnoresCancellationDoesNotHoldTheFeedBackEither() async {
        // A request that waits for something shared (a visitor token being fetched) does not react to cancellation.
        let stuck = UncancellableGate()
        let source = RelatedSource(related: ["h1": [makeVideo("late")], "h2": [makeVideo("c")]], stuck: ["h1"], gate: stuck)
        let timeIsUp = UncancellableGate()
        let service = makeService(source, timeIsUp: timeIsUp)
        let history = [makeEntry("h1"), makeEntry("h2")]
        // If the service did wait for the stuck seed, the test would hang for ever; this makes it fail instead.
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(20))
            stuck.open()
        }
        defer { watchdog.cancel() }

        let call = Task { await service.homeFeed(history: history, subscriptionVideos: []) }
        #expect(await eventually { await source.finished == ["h2"] })
        await settle()
        timeIsUp.open()
        let first = await call.value

        #expect(first.forYou.map(\.id) == ["c"])
        #expect(await source.finished == ["h2"], "the stuck seed is still stuck")

        // When it finally answers, nothing happens to the feed that was handed over (and nothing resumes twice).
        stuck.open()
        #expect(await eventually { await source.finished.sorted() == ["h1", "h2"] })
        #expect(first.forYou.map(\.id) == ["c"])
        // The next feed sees the answer that came too late for the first.
        let second = await makeService(source, timeout: .seconds(3_600)).homeFeed(history: history, subscriptionVideos: [])
        #expect(second.forYou.map(\.id) == ["late", "c"])
    }

    @Test(.timeLimit(.minutes(1)))
    func theDeadlineDoesNotHoldBackAFeedWhoseSeedsAllAnswered() async {
        let source = RelatedSource(related: ["h1": [makeVideo("a")], "h2": [makeVideo("b")]])
        let service = makeService(source, timeout: .seconds(3_600))

        let feed = await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2")], subscriptionVideos: [])

        #expect(feed.forYou.map(\.id) == ["a", "b"])
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheCallerEndsTheWaitAtOnceAndCancelsTheSeeds() async {
        let source = RelatedSource(hanging: ["h1"])
        let service = makeService(source, timeout: .seconds(3_600))
        let subscriptions = [makeVideo("s1", daysAgo: 30)]

        let call = Task { await service.homeFeed(history: [makeEntry("h1")], subscriptionVideos: subscriptions) }
        #expect(await eventually { await source.requested == ["h1"] })
        call.cancel()
        let feed = await call.value

        // Nothing was learned about the seed, so the feed is what it is without any: the subscriptions.
        #expect(feed.forYou.map(\.id) == ["s1"])
        #expect(await eventually { await source.cancelled == ["h1"] })
    }

    @Test(.timeLimit(.minutes(1)))
    func aCallerThatIsAlreadyCancelledStillGetsAFeed() async {
        let source = RelatedSource(hanging: ["h1"])
        let service = makeService(source, timeout: .seconds(3_600))
        let call = Task {
            while !Task.isCancelled { await Task.yield() }
            return await service.homeFeed(history: [makeEntry("h1")], subscriptionVideos: [makeVideo("s1", daysAgo: 30)])
        }
        call.cancel()
        let feed = await call.value
        #expect(feed.forYou.map(\.id) == ["s1"])
    }

    // MARK: Composition

    @Test func relatedVideosArePassedOnUnfilteredExceptForRepeats() async {
        // Shorts and members-only videos are the content filter's business, not this service's.
        let source = RelatedSource(related: ["h1": [makeVideo("short", isShort: true), makeVideo("ok")]])
        let service = makeService(source)

        let feed = await service.homeFeed(history: [makeEntry("h1")], subscriptionVideos: [])

        #expect(feed.forYou.map(\.id) == ["short", "ok"])
    }

    @Test func subscriptionVideosFillTheRestOnceRelatedOnesRunOut() async {
        let source = RelatedSource(related: ["h1": [makeVideo("r1")]])
        let service = makeService(source)
        let subscriptions = [makeVideo("s1", daysAgo: 1), makeVideo("s2", daysAgo: 2), makeVideo("s3", daysAgo: 20)]

        let feed = await service.homeFeed(history: [makeEntry("h1")], subscriptionVideos: subscriptions)

        // Only fresh uploads are mixed in; the 20-day-old one is not.
        #expect(feed.forYou.map(\.id) == ["r1", "s1", "s2"])
    }

    @Test func aSubscriptionVideoThatIsAlsoRelatedAppearsOnce() async {
        let source = RelatedSource(related: ["h1": [makeVideo("x"), makeVideo("s1"), makeVideo("y")]])
        let service = makeService(source)

        let feed = await service.homeFeed(history: [makeEntry("h1")], subscriptionVideos: [makeVideo("s1", daysAgo: 1), makeVideo("s2", daysAgo: 1)])

        #expect(feed.forYou.map(\.id) == ["x", "s1", "s2", "y"])
    }

    @Test func theFeedHoldsAtMostSixtyVideos() async {
        var relatedBySeed: [String: [VideoSummary]] = [:]
        for seed in 1...6 {
            relatedBySeed["h\(seed)"] = (1...12).map { makeVideo("r\($0)-of-h\(seed)") }
        }
        let source = RelatedSource(related: relatedBySeed)
        let service = makeService(source)
        let subscriptions = (1...30).map { makeVideo("s\($0)", daysAgo: 1) }

        let feed = await service.homeFeed(history: (1...6).map { makeEntry("h\($0)") }, subscriptionVideos: subscriptions)

        #expect(feed.forYou.count == 60)
        #expect(Set(feed.forYou.map(\.id)).count == 60)
        // 72 related videos and 30 fresh uploads compete; the first 60 slots keep the every-third pattern.
        #expect(feed.forYou.enumerated().filter { $0.element.id.hasPrefix("s") }.map(\.offset) == Array(stride(from: 2, to: 60, by: 3)))
    }

    @Test func withoutAnyRelatedVideosTheSubscriptionsStandIn() async {
        let source = RelatedSource(failing: ["h1"])
        let service = makeService(source)
        let subscriptions = [makeVideo("old", daysAgo: 30), makeVideo("seen", daysAgo: 40), makeVideo("older", daysAgo: 50)]

        let feed = await service.homeFeed(history: [makeEntry("h1"), makeEntry("seen")], subscriptionVideos: subscriptions)

        // Offline or not: something to watch, minus what is already in the history.
        #expect(feed.forYou.map(\.id) == ["old", "older"])
    }

    @Test func subscriptionDuplicatesAreDropped() async {
        let source = RelatedSource()
        let service = makeService(source)

        let feed = await service.homeFeed(history: [], subscriptionVideos: [makeVideo("a"), makeVideo("b"), makeVideo("a")])

        #expect(feed.forYou.map(\.id) == ["a", "b"])
    }

    @Test func nothingAtAllGivesAnEmptyFeed() async {
        let service = makeService(RelatedSource())
        let feed = await service.homeFeed(history: [], subscriptionVideos: [])
        #expect(feed.forYou.isEmpty && feed.continueWatching.isEmpty)
    }

    // MARK: When YouTube cannot be asked
    //
    // "For you" with nothing in it is either "nothing more to suggest" (YouTube answered) or "could not load" (it did
    // not): the screen has to tell the two apart, so the feed says which one it is.

    @Test func relatedVideosAreUnavailableWhenNoSeedAnswers() async {
        let service = makeService(RelatedSource(failing: ["h1", "h2"]))

        let feed = await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2")], subscriptionVideos: [])

        #expect(feed.relatedUnavailable)
        #expect(feed.forYou.isEmpty)
        // "Continue watching" needs no network.
        #expect(feed.continueWatching.map(\.id) == ["h1", "h2"])
    }

    @Test(.timeLimit(.minutes(1)))
    func relatedVideosAreUnavailableWhenNoSeedAnswersBeforeTheDeadline() async {
        let source = RelatedSource(hanging: ["h1", "h2"])
        let timeIsUp = UncancellableGate()
        let service = makeService(source, timeIsUp: timeIsUp)

        let call = Task { await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2")], subscriptionVideos: []) }
        #expect(await eventually { await source.requested.sorted() == ["h1", "h2"] })
        timeIsUp.open()
        let feed = await call.value

        #expect(feed.relatedUnavailable)
        #expect(feed.forYou.isEmpty)
    }

    @Test func subscriptionUploadsStillFillTheFeedWhenRelatedVideosAreUnavailable() async {
        let service = makeService(RelatedSource(failing: ["h1"]))

        let feed = await service.homeFeed(history: [makeEntry("h1")], subscriptionVideos: [makeVideo("s1", daysAgo: 30)])

        #expect(feed.relatedUnavailable)
        #expect(feed.forYou.map(\.id) == ["s1"])
    }

    @Test func relatedVideosAreAvailableWithoutAHistory() async {
        let source = RelatedSource()
        let service = makeService(source)

        let feed = await service.homeFeed(history: [], subscriptionVideos: [makeVideo("s1", daysAgo: 1)])

        #expect(!feed.relatedUnavailable)
        #expect(await source.requested.isEmpty)
    }

    @Test func aHistoryOfShortsAloneHasNothingToAskAbout() async {
        let service = makeService(RelatedSource())
        let feed = await service.homeFeed(history: [makeEntry("s1", isShort: true)], subscriptionVideos: [])
        #expect(!feed.relatedUnavailable)
    }

    @Test func nothingWasAskedWithoutASeedBudgetEither() async {
        let service = makeService(RelatedSource(), maxSeeds: 0)
        let feed = await service.homeFeed(history: [makeEntry("h1")], subscriptionVideos: [])
        #expect(!feed.relatedUnavailable)
    }

    @Test func seedsThatAnswerWithNoRelatedVideosHaveAnswered() async {
        // YouTube was reached; it just had nothing to suggest. That is "that is everything", not "could not load".
        let service = makeService(RelatedSource(related: ["h1": [], "h2": []]))

        let feed = await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2")], subscriptionVideos: [])

        #expect(!feed.relatedUnavailable)
        #expect(feed.forYou.isEmpty)
    }

    @Test func oneSeedFailingWhileAnotherAnswersIsNotUnavailable() async {
        let service = makeService(RelatedSource(related: ["h2": [makeVideo("c")]], failing: ["h1"]))

        let feed = await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2")], subscriptionVideos: [])

        #expect(!feed.relatedUnavailable)
        #expect(feed.forYou.map(\.id) == ["c"])
    }

    @Test(.timeLimit(.minutes(1)))
    func oneSeedAnsweringBeforeTheDeadlineIsEnough() async {
        let source = RelatedSource(related: ["h2": [makeVideo("c")]], hanging: ["h1"])
        let timeIsUp = UncancellableGate()
        let service = makeService(source, timeIsUp: timeIsUp)

        let call = Task { await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2")], subscriptionVideos: []) }
        #expect(await eventually { await source.finished == ["h2"] })
        await settle()
        timeIsUp.open()
        let feed = await call.value

        #expect(!feed.relatedUnavailable)
        #expect(feed.forYou.map(\.id) == ["c"])
    }

    // MARK: Continue watching without the service

    @Test func continueWatchingIsTheSameRuleWithOrWithoutTheService() async {
        var history: [HistoryEntry] = [
            makeEntry("too-short", progress: 29.9),
            makeEntry("exactly-30", progress: 30),
            makeEntry("finished", progress: 595, duration: 600),
            makeEntry("short-video", progress: 100, isShort: true),
            makeEntry("unknown-duration", progress: 500, duration: nil),
        ]
        history += (1...12).map { makeEntry("keep-\($0)", progress: 60 + Double($0)) }
        let expected = ["exactly-30", "unknown-duration"] + (1...8).map { "keep-\($0)" }

        let early = HomeFeed.continueWatching(in: history)
        let built = await makeService(RelatedSource()).homeFeed(history: history, subscriptionVideos: []).continueWatching

        #expect(early.map(\.id) == expected)
        #expect(built == early)
    }

    @Test func continueWatchingOfNoHistoryIsEmpty() {
        #expect(HomeFeed.continueWatching(in: []).isEmpty)
    }
}
