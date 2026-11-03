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

/// A `YouTubeService` that only knows watch pages: `related` lists the related videos of each seed.
private actor RelatedSource: YouTubeService {
    private let related: [String: [VideoSummary]]
    private let failing: Set<String>
    private let hanging: Set<String>
    private let delay: Duration
    private(set) var requested: [String] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(
        related: [String: [VideoSummary]] = [:],
        failing: Set<String> = [],
        hanging: Set<String> = [],
        delay: Duration = .zero
    ) {
        self.related = related
        self.failing = failing
        self.hanging = hanging
        self.delay = delay
    }

    func videoDetails(id: String) async throws -> VideoDetails {
        requested.append(id)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if hanging.contains(id) {
            do { try await Task.sleep(for: .seconds(3_600)) } catch { throw NoSlopError.cancelled }
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

private func makeService(_ source: RelatedSource, maxSeeds: Int = 6, timeout: Duration = .seconds(10)) -> HomeFeedService {
    HomeFeedService(youTube: source, maxSeeds: maxSeeds, fetchTimeout: timeout, now: { now })
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

    @Test func seedsAreFetchedConcurrently() async {
        let source = RelatedSource(related: [:], delay: .milliseconds(150))
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

    @Test func aSeedThatNeverAnswersDoesNotHoldTheFeedBack() async {
        let source = RelatedSource(related: ["h2": [makeVideo("c")]], hanging: ["h1"])
        let service = makeService(source, timeout: .milliseconds(300))

        let started = ContinuousClock.now
        let feed = await service.homeFeed(history: [makeEntry("h1"), makeEntry("h2")], subscriptionVideos: [])
        let elapsed = ContinuousClock.now - started

        #expect(feed.forYou.map(\.id) == ["c"])
        #expect(elapsed < .seconds(5))
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
}
