import Foundation
import Testing
@testable import NoSlopKit

// Whole seconds survive the ISO 8601 cache file exactly, so a reloaded feed compares equal.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func makeVideo(
    _ id: String,
    channel: String? = nil,
    daysAgo: Double? = nil,
    duration: Int? = nil,
    isShort: Bool = false
) -> VideoSummary {
    VideoSummary(
        id: id,
        title: "Video \(id)",
        channel: channel.map { ChannelRef(id: $0, name: "Channel \($0)") },
        durationSeconds: duration,
        publishedAt: daysAgo.map { t0.addingTimeInterval(-$0 * 86_400) },
        isShort: isShort
    )
}

private func makeChannel(_ id: String, avatar: String? = nil) -> SubscribedChannel {
    SubscribedChannel(id: id, name: "Channel \(id)", avatarURL: avatar.flatMap(URL.init(string:)))
}

private let channelA = makeChannel("UC_A")
private let channelB = makeChannel("UC_B")
private let channelC = makeChannel("UC_C")

/// A clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = t0) {
        current = start
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// An RSS source with scripted answers per channel that records what was asked and how many calls overlapped.
private actor ScriptedRSS: RSSFeedFetching {
    enum Reply: Sendable {
        case videos([VideoSummary])
        case failure(NoSlopError)
        /// Never answers: the request is suspended until it is cancelled (a stalled connection).
        case hang
    }

    private var replies: [String: Reply]
    private let delay: Duration
    private(set) var requested: [String] = []
    /// The requests that were given an answer (videos or a failure), not those that hung or were cancelled.
    private(set) var answered = 0
    /// The requests that were cancelled while they waited.
    private(set) var cancelled: [String] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private var isHeld = false

    init(_ replies: [String: Reply], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    func reply(_ channelID: String, with reply: Reply) {
        replies[channelID] = reply
    }

    /// From now on a request waits, after it was counted, until `release()` (or until it is cancelled). It keeps a
    /// refresh running for as long as a test needs another caller to arrive.
    func hold() {
        isHeld = true
    }

    func release() {
        isHeld = false
    }

    func latestVideos(channelID: String) async throws -> [VideoSummary] {
        requested.append(channelID)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        do {
            if delay > .zero { try await Task.sleep(for: delay) }
            while isHeld { try await Task.sleep(for: .milliseconds(2)) }
            if case .hang? = replies[channelID] { try await Task.sleep(for: .seconds(3_600)) }
        } catch {
            cancelled.append(channelID)
            throw error
        }
        answered += 1
        switch replies[channelID] {
        case .videos(let videos): return videos
        case .failure(let error): throw error
        case .hang, nil: return []
        }
    }
}

/// An account service that only knows `durations`.
private actor ScriptedAccount: YouTubeAccountService {
    private let known: [String: Int]
    private let failure: NoSlopError?
    private var hangs: Bool
    private(set) var batches: [[String]] = []

    init(durations: [String: Int] = [:], failure: NoSlopError? = nil, hangs: Bool = false) {
        self.known = durations
        self.failure = failure
        self.hangs = hangs
    }

    /// From now on the lookups answer (or hang) again.
    func hang(_ hangs: Bool) {
        self.hangs = hangs
    }

    func durations(videoIDs: [String]) async throws -> [String: Int] {
        batches.append(videoIDs)
        if hangs { try await Task.sleep(for: .seconds(3_600)) }
        if let failure { throw failure }
        return known.filter { videoIDs.contains($0.key) }
    }

    func subscriptions() async throws -> [SubscribedChannel] { throw NoSlopError.notImplemented("ScriptedAccount.subscriptions") }
    func subscribe(channelID: String) async throws -> String { throw NoSlopError.notImplemented("ScriptedAccount.subscribe") }
    func unsubscribe(subscriptionID: String) async throws { throw NoSlopError.notImplemented("ScriptedAccount.unsubscribe") }
    func myPlaylists() async throws -> [PlaylistSummary] { throw NoSlopError.notImplemented("ScriptedAccount.myPlaylists") }
    func playlistItems(playlistID: String, pageToken: String?) async throws -> Page<VideoSummary> {
        throw NoSlopError.notImplemented("ScriptedAccount.playlistItems")
    }
    func likedVideos(pageToken: String?) async throws -> Page<VideoSummary> { throw NoSlopError.notImplemented("ScriptedAccount.likedVideos") }
    func rating(videoID: String) async throws -> VideoRating { throw NoSlopError.notImplemented("ScriptedAccount.rating") }
    func rate(videoID: String, rating: VideoRating) async throws { throw NoSlopError.notImplemented("ScriptedAccount.rate") }
    func addToPlaylist(videoID: String, playlistID: String) async throws { throw NoSlopError.notImplemented("ScriptedAccount.addToPlaylist") }
}

@Suite final class SubscriptionFeedServiceTests {
    /// A directory of its own per test; the cache file lives in a sub-folder that does not exist yet.
    private let directory: URL
    private let cacheURL: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSlopFeedTests-\(UUID().uuidString)", isDirectory: true)
        cacheURL = directory.appendingPathComponent("caches/subscription-feed.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: From the plan

    @Test func mergesSortsDedupes() async throws {
        let rss = ScriptedRSS([
            "UC_A": .videos([makeVideo("a-old", daysAgo: 5), makeVideo("shared", daysAgo: 4), makeVideo("a-new", daysAgo: 2)]),
            "UC_B": .videos([makeVideo("b1", daysAgo: 3), makeVideo("shared", daysAgo: 4)]),
            "UC_C": .videos([makeVideo("c1", daysAgo: 1), makeVideo("undated")]),
        ])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)

        let feed = try await service.feed(channels: [channelA, channelB, channelC], forceRefresh: true)

        // Newest first, every id once, videos without a date last.
        #expect(feed.map(\.id) == ["c1", "a-new", "b1", "shared", "a-old", "undated"])
        #expect(Set(feed.map(\.id)).count == feed.count)
    }

    @Test func partialFailureStillReturns() async throws {
        let rss = ScriptedRSS([
            "UC_A": .videos([makeVideo("a1", daysAgo: 2)]),
            "UC_B": .failure(.network("down")),
            "UC_C": .videos([makeVideo("c1", daysAgo: 1)]),
        ])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)

        let feed = try await service.feed(channels: [channelA, channelB, channelC], forceRefresh: true)

        #expect(feed.map(\.id) == ["c1", "a1"])
    }

    @Test func allFailThrows() async {
        let rss = ScriptedRSS([
            "UC_A": .failure(.network("offline")),
            "UC_B": .failure(.network("offline")),
            "UC_C": .failure(.network("offline")),
        ])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)

        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await service.feed(channels: [channelA, channelB, channelC], forceRefresh: true)
        }
    }

    @Test func fillsDurationsFromAccount() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([
            makeVideo("v1", channel: "UC_A", daysAgo: 1),
            makeVideo("v2", channel: "UC_A", daysAgo: 2, duration: 99),
            makeVideo("v3", channel: "UC_A", daysAgo: 3),
        ])])
        let account = ScriptedAccount(durations: ["v1": 600, "v2": 5, "v3": 61])
        let service = SubscriptionFeedService(rss: rss, account: account, cacheURL: nil)

        let feed = try await service.feed(channels: [channelA], forceRefresh: true)

        // A duration that is already known stays; only the missing ones are asked for.
        #expect(feed.map(\.durationSeconds) == [600, 99, 61])
        #expect(await account.batches == [["v1", "v3"]])

        // Not signed in: the items stay as RSS delivered them, and nothing is thrown.
        let videos = [makeVideo("v1", channel: "UC_A", daysAgo: 1), makeVideo("v2", channel: "UC_A", daysAgo: 2)]
        let signedOut = ScriptedAccount(failure: .notSignedIn)
        let offlineService = SubscriptionFeedService(rss: ScriptedRSS(["UC_A": .videos(videos)]), account: signedOut, cacheURL: nil)

        let unchanged = try await offlineService.feed(channels: [channelA], forceRefresh: true)

        #expect(unchanged == videos)
        #expect(unchanged.allSatisfy { $0.durationSeconds == nil })
        #expect(await signedOut.batches.count == 1, "one attempt, not one per batch")
    }

    @Test func cacheRoundTrip() async throws {
        let rss = ScriptedRSS([
            "UC_A": .videos([makeVideo("a1", channel: "UC_A", daysAgo: 2, duration: 300), makeVideo("a2", channel: "UC_A", daysAgo: 4, isShort: true)]),
            "UC_B": .videos([makeVideo("b1", channel: "UC_B", daysAgo: 1)]),
        ])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL)
        #expect(await service.cachedFeed().isEmpty)

        let fresh = try await service.feed(channels: [channelA, channelB], forceRefresh: true)
        #expect(fresh.count == 3)

        let restarted = SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL)
        let cached = await restarted.cachedFeed()
        #expect(cached == fresh)
        #expect(await service.cachedFeed() == fresh)
    }

    // MARK: Fetching

    @Test func eachChannelIsFetchedOnceAndEmptyChannelListsAreFine() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("a1", daysAgo: 1)])])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)

        #expect(try await service.feed(channels: [], forceRefresh: true).isEmpty)
        #expect(await rss.requested.isEmpty)

        let feed = try await service.feed(channels: [channelA, channelA], forceRefresh: true)
        #expect(feed.map(\.id) == ["a1"])
        #expect(await rss.requested == ["UC_A"])
    }

    @Test func atMostMaxConcurrentChannelsAreFetchedAtOnce() async throws {
        let channels = (0..<10).map { makeChannel("UC_\($0)") }
        let rss = ScriptedRSS(
            Dictionary(uniqueKeysWithValues: channels.map { ($0.id, ScriptedRSS.Reply.videos([makeVideo("v-\($0.id)", daysAgo: 1)])) }),
            delay: .milliseconds(100)
        )
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil, maxConcurrent: 3)

        let feed = try await service.feed(channels: channels, forceRefresh: true)

        #expect(feed.count == 10)
        #expect(await rss.requested.count == 10)
        #expect(await rss.maxInFlight == 3)
    }

    @Test func aSingleSlotFetchesOneByOne() async throws {
        let channels = (0..<4).map { makeChannel("UC_\($0)") }
        let rss = ScriptedRSS(Dictionary(uniqueKeysWithValues: channels.map { ($0.id, ScriptedRSS.Reply.videos([]))}), delay: .milliseconds(10))
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil, maxConcurrent: 0)

        _ = try await service.feed(channels: channels, forceRefresh: true)

        #expect(await rss.maxInFlight == 1)
        #expect(await rss.requested.count == 4)
    }

    @Test func channelsAreCachedForFifteenMinutesUnlessRefreshIsForced() async throws {
        let clock = ManualClock()
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("a1", daysAgo: 1)]), "UC_B": .videos([makeVideo("b1", daysAgo: 2)])])
        let service = SubscriptionFeedService(
            rss: rss, account: nil, cacheURL: nil, maxConcurrent: 8, channelCacheTTL: 900, now: { clock.now }
        )

        _ = try await service.feed(channels: [channelA, channelB], forceRefresh: false)
        #expect(await rss.requested.count == 2)

        _ = try await service.feed(channels: [channelA, channelB], forceRefresh: false)
        clock.advance(by: 899)
        let cached = try await service.feed(channels: [channelA, channelB], forceRefresh: false)
        #expect(await rss.requested.count == 2)
        #expect(cached.map(\.id) == ["a1", "b1"])

        // Forcing a refresh asks again.
        _ = try await service.feed(channels: [channelA, channelB], forceRefresh: true)
        #expect(await rss.requested.count == 4)

        // So does the cache running out, and a new subscription only costs its own request.
        clock.advance(by: 901)
        _ = try await service.feed(channels: [channelA, channelB], forceRefresh: false)
        #expect(await rss.requested.count == 6)
        _ = try await service.feed(channels: [channelA, channelB, channelC], forceRefresh: false)
        #expect(await rss.requested.count == 7)
        #expect(await rss.requested.last == "UC_C")
    }

    @Test func aCachedFeedForgetsChannelsThatWereUnsubscribed() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("a1", daysAgo: 1)]), "UC_B": .videos([makeVideo("b1", daysAgo: 2)])])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)

        _ = try await service.feed(channels: [channelA, channelB], forceRefresh: false)
        let afterUnsubscribe = try await service.feed(channels: [channelB], forceRefresh: false)

        #expect(afterUnsubscribe.map(\.id) == ["b1"])
    }

    @Test func videosAreAttributedToTheirSubscribedChannel() async throws {
        let withAvatar = makeChannel("UC_A", avatar: "https://example.com/a.jpg")
        let rss = ScriptedRSS(["UC_A": .videos([
            makeVideo("no-channel", daysAgo: 1),
            makeVideo("no-avatar", channel: "UC_A", daysAgo: 2),
            VideoSummary(
                id: "has-avatar", title: "t",
                channel: ChannelRef(id: "UC_A", name: "Own name", avatarURL: URL(string: "https://example.com/own.jpg")),
                publishedAt: t0.addingTimeInterval(-3 * 86_400)
            ),
        ])])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)

        let feed = try await service.feed(channels: [withAvatar], forceRefresh: true)

        let byID = Dictionary(uniqueKeysWithValues: feed.map { ($0.id, $0) })
        #expect(byID["no-channel"]?.channel == ChannelRef(id: "UC_A", name: "Channel UC_A", avatarURL: URL(string: "https://example.com/a.jpg")))
        #expect(byID["no-avatar"]?.channel?.avatarURL == URL(string: "https://example.com/a.jpg"))
        #expect(byID["has-avatar"]?.channel == ChannelRef(id: "UC_A", name: "Own name", avatarURL: URL(string: "https://example.com/own.jpg")))
        #expect(feed.count == 3)
    }

    // MARK: Failures

    @Test func theFirstChannelsErrorIsThrownWhenEverythingFails() async {
        let rss = ScriptedRSS(["UC_A": .failure(.http(status: 500)), "UC_B": .failure(.network("x")), "UC_C": .failure(.network("y"))])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)

        await #expect(throws: NoSlopError.http(status: 500)) {
            _ = try await service.feed(channels: [channelA, channelB, channelC], forceRefresh: true)
        }
    }

    @Test func aFailingChannelKeepsItsPreviousVideos() async throws {
        let rss = ScriptedRSS([
            "UC_A": .videos([makeVideo("a1", channel: "UC_A", daysAgo: 3)]),
            "UC_B": .videos([makeVideo("b1", channel: "UC_B", daysAgo: 2)]),
        ])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)
        _ = try await service.feed(channels: [channelA, channelB], forceRefresh: true)

        await rss.reply("UC_A", with: .videos([makeVideo("a2", channel: "UC_A", daysAgo: 1), makeVideo("a1", channel: "UC_A", daysAgo: 3)]))
        await rss.reply("UC_B", with: .failure(.network("blip")))
        let feed = try await service.feed(channels: [channelA, channelB], forceRefresh: true)

        // B could not be refreshed, but its videos do not vanish from the feed.
        #expect(feed.map(\.id) == ["a2", "b1", "a1"])
    }

    @Test func aFailingChannelKeepsItsVideosFromTheDiskCacheAfterARestart() async throws {
        let first = ScriptedRSS([
            "UC_A": .videos([makeVideo("a1", channel: "UC_A", daysAgo: 3)]),
            "UC_B": .videos([makeVideo("b1", channel: "UC_B", daysAgo: 2)]),
        ])
        _ = try await SubscriptionFeedService(rss: first, account: nil, cacheURL: cacheURL)
            .feed(channels: [channelA, channelB], forceRefresh: true)

        let second = ScriptedRSS(["UC_A": .videos([makeVideo("a2", channel: "UC_A", daysAgo: 1)]), "UC_B": .failure(.network("blip"))])
        let restarted = SubscriptionFeedService(rss: second, account: nil, cacheURL: cacheURL)
        let feed = try await restarted.feed(channels: [channelA, channelB], forceRefresh: false)

        #expect(feed.map(\.id) == ["a2", "b1"])
        #expect(await restarted.cachedFeed() == feed)
    }

    @Test func aFailedRefreshLeavesTheCachedFeedAlone() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("a1", channel: "UC_A", daysAgo: 1)])])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL)
        let good = try await service.feed(channels: [channelA], forceRefresh: true)

        await rss.reply("UC_A", with: .failure(.network("offline")))
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await service.feed(channels: [channelA], forceRefresh: true)
        }

        #expect(await service.cachedFeed() == good)
        #expect(await SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL).cachedFeed() == good)
    }

    // MARK: Durations

    @Test func durationsAreLookedUpInBatchesOfFifty() async throws {
        let videos = (0..<120).map { makeVideo("v\($0)", channel: "UC_A", daysAgo: Double($0) / 10) }
        let rss = ScriptedRSS(["UC_A": .videos(videos)])
        let account = ScriptedAccount(durations: Dictionary(uniqueKeysWithValues: videos.map { ($0.id, 100 + (Int($0.id.dropFirst()) ?? 0)) }))
        let service = SubscriptionFeedService(rss: rss, account: account, cacheURL: nil)

        let feed = try await service.feed(channels: [channelA], forceRefresh: true)

        let batches = await account.batches
        #expect(batches.map(\.count).sorted() == [20, 50, 50])
        #expect(Set(batches.flatMap { $0 }) == Set(videos.map(\.id)))
        #expect(feed.allSatisfy { $0.durationSeconds != nil })
        #expect(feed.first { $0.id == "v7" }?.durationSeconds == 107)
    }

    @Test func anAccountThatFailsIsAskedOnlyOnceNotForEveryBatch() async throws {
        let videos = (0..<120).map { makeVideo("v\($0)", channel: "UC_A", daysAgo: Double($0) / 10) }
        let rss = ScriptedRSS(["UC_A": .videos(videos)])
        let account = ScriptedAccount(failure: .quotaExceeded)
        let service = SubscriptionFeedService(rss: rss, account: account, cacheURL: nil)

        let feed = try await service.feed(channels: [channelA], forceRefresh: true)

        #expect(feed.count == 120)
        #expect(await account.batches.count == 1)
    }

    @Test func knownDurationsAreNotAskedForAgain() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("v1", channel: "UC_A", daysAgo: 2), makeVideo("v2", channel: "UC_A", daysAgo: 3)])])
        let account = ScriptedAccount(durations: ["v1": 60, "v2": 120, "v3": 180])
        let service = SubscriptionFeedService(rss: rss, account: account, cacheURL: nil)
        _ = try await service.feed(channels: [channelA], forceRefresh: true)

        await rss.reply("UC_A", with: .videos([
            makeVideo("v3", channel: "UC_A", daysAgo: 1), makeVideo("v1", channel: "UC_A", daysAgo: 2), makeVideo("v2", channel: "UC_A", daysAgo: 3),
        ]))
        let feed = try await service.feed(channels: [channelA], forceRefresh: true)

        #expect(feed.map(\.durationSeconds) == [180, 60, 120])
        #expect(await account.batches == [["v1", "v2"], ["v3"]])
    }

    @Test func durationsLearnedEarlierSurviveARestart() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("v1", channel: "UC_A", daysAgo: 1)])])
        let account = ScriptedAccount(durations: ["v1": 60])
        _ = try await SubscriptionFeedService(rss: rss, account: account, cacheURL: cacheURL).feed(channels: [channelA], forceRefresh: true)

        let offline = ScriptedAccount(failure: .notSignedIn)
        let restarted = SubscriptionFeedService(rss: rss, account: offline, cacheURL: cacheURL)
        let feed = try await restarted.feed(channels: [channelA], forceRefresh: true)

        #expect(feed.first?.durationSeconds == 60)
        #expect(await offline.batches.isEmpty, "nothing needed to be looked up")
    }

    @Test func aZeroDurationMeansLiveOrUnknownAndIsNotStored() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("live", channel: "UC_A", daysAgo: 1)])])
        let account = ScriptedAccount(durations: ["live": 0])
        let service = SubscriptionFeedService(rss: rss, account: account, cacheURL: nil)

        let feed = try await service.feed(channels: [channelA], forceRefresh: true)

        #expect(feed.first?.durationSeconds == nil)
    }

    @Test func noAccountMeansNoDurations() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("v1", channel: "UC_A", daysAgo: 1)])])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)
        #expect(try await service.feed(channels: [channelA], forceRefresh: true).first?.durationSeconds == nil)
    }

    // MARK: Disk cache

    @Test func theCacheFileIsCreatedWithItsFolderAndOnlyAfterARefresh() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("a1", daysAgo: 1)])])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL)
        #expect(await service.cachedFeed().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))

        _ = try await service.feed(channels: [channelA], forceRefresh: true)

        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    @Test func aDamagedCacheFileIsMovedAsideAndTheFeedStartsEmpty() async throws {
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{garbage".utf8).write(to: cacheURL)
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("a1", daysAgo: 1)])])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL)

        #expect(await service.cachedFeed().isEmpty)
        #expect(FileManager.default.fileExists(atPath: cacheURL.appendingPathExtension("corrupt").path))
        #expect(!FileManager.default.fileExists(atPath: cacheURL.path))

        let feed = try await service.feed(channels: [channelA], forceRefresh: true)
        #expect(feed.map(\.id) == ["a1"])
        #expect(await SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL).cachedFeed() == feed)
    }

    @Test func withoutACacheURLNothingIsWritten() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("a1", daysAgo: 1)])])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: nil)

        let feed = try await service.feed(channels: [channelA], forceRefresh: true)

        #expect(await service.cachedFeed() == feed)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func anEmptySubscriptionListClearsTheCachedFeed() async throws {
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("a1", daysAgo: 1)])])
        let service = SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL)
        _ = try await service.feed(channels: [channelA], forceRefresh: true)

        #expect(try await service.feed(channels: [], forceRefresh: true).isEmpty)

        #expect(await service.cachedFeed().isEmpty)
        #expect(await SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL).cachedFeed().isEmpty)
    }
}

// MARK: - A refresh that does not wait for ever
//
// A channel that does not answer must not hold the others back, and a stalled connection (every request waiting for
// its own time-out, eight at a time) must not keep the screens on their skeletons for minutes. After the deadline no
// new request is started, the ones still running are cancelled, what had arrived is kept, and the channels that did
// not answer count as failed for this refresh, so the next one asks for them first.
//
// The tests make the moment the time is up their own (`FetchDeadline.when`) instead of racing a clock. The channels
// that must not answer hang until they are cancelled, and the moment is chosen by counting requests: with one slot
// per request the n-th request starts only after the (n-1)-th answer has been taken in, so "n requests have been
// made" says exactly which answers the service has. Nothing here depends on how fast the machine is.

/// Suspends until `condition` holds, for at most 30 seconds, and ends early when the task is cancelled.
private func waitUntil(_ condition: @Sendable () async -> Bool) async {
    let limit = ContinuousClock.now + .seconds(30)
    while !Task.isCancelled, ContinuousClock.now < limit, !(await condition()) {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// The outcome of `operation`, or nil when it has not finished within `limit` (it is cancelled then). A feed that
/// waits for ever fails a test this way instead of hanging it.
private func finishing<T: Sendable>(
    within limit: Duration = .seconds(20),
    _ operation: @escaping @Sendable () async throws -> T
) async -> Result<T, any Error>? {
    await withTaskGroup(of: Result<T, any Error>?.self) { group in
        group.addTask {
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// A number the test changes while the service is running.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int

    init(_ start: Int) {
        current = start
    }

    var value: Int {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// The time is up as soon as `rss` has been asked `target.value` times (and never, for `Int.max`).
private func afterRequests(_ rss: ScriptedRSS, _ target: Counter) -> FetchDeadline {
    .when { await waitUntil { await rss.requested.count >= target.value } }
}

@Suite final class SubscriptionFeedDeadlineTests {
    private let directory: URL
    private let cacheURL: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSlopFeedDeadlineTests-\(UUID().uuidString)", isDirectory: true)
        cacheURL = directory.appendingPathComponent("caches/subscription-feed.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func channels(_ count: Int) -> [SubscribedChannel] {
        (0..<count).map { makeChannel("UC_\($0)") }
    }

    private func video(of channel: SubscribedChannel, daysAgo: Double) -> VideoSummary {
        makeVideo("v-\(channel.id)", channel: channel.id, daysAgo: daysAgo)
    }

    /// The first `answering` channels answer at once, every other one hangs.
    private func scripted(_ channels: [SubscribedChannel], answering: Int) -> ScriptedRSS {
        var replies: [String: ScriptedRSS.Reply] = [:]
        for (index, channel) in channels.enumerated() {
            replies[channel.id] = index < answering ? .videos([video(of: channel, daysAgo: Double(index))]) : .hang
        }
        return ScriptedRSS(replies)
    }

    private func makeService(
        _ rss: ScriptedRSS, account: ScriptedAccount? = nil, maxConcurrent: Int, cache: URL? = nil, deadline: FetchDeadline
    ) -> SubscriptionFeedService {
        SubscriptionFeedService(
            rss: rss, account: account, cacheURL: cache, maxConcurrent: maxConcurrent,
            channelCacheTTL: 900, fetchDeadline: deadline, now: { t0 }
        )
    }

    // MARK: Channels

    @Test func theChannelsThatAnsweredAreKeptAndTheOthersAreLeftBehind() async throws {
        // 24 channels, four requests at a time. The first eight answer; then four hang and occupy every slot, so
        // without a deadline nothing would ever move on. Four requests start at once and one more after each of the
        // eight answers: when 12 have been made the service has all eight.
        let channels = channels(24)
        let rss = scripted(channels, answering: 8)
        let service = makeService(rss, maxConcurrent: 4, deadline: afterRequests(rss, Counter(12)))

        let outcome = await finishing { try await service.feed(channels: channels, forceRefresh: true) }

        let feed = try #require(try outcome?.get(), "the refresh went on waiting for the channels that do not answer")
        #expect(feed.map(\.id) == (0..<8).map { "v-UC_\($0)" })
        #expect(await rss.requested.count == 12, "no request was started after the deadline")
        #expect(await rss.maxInFlight <= 4)

        // The four requests that were still running were cancelled.
        await waitUntil { await rss.cancelled.count >= 4 }
        #expect(Set(await rss.cancelled) == ["UC_8", "UC_9", "UC_10", "UC_11"])

        // What is shown is what the next start shows, too.
        #expect(await service.cachedFeed() == feed)
    }

    @Test func theNextRefreshAsksOnlyForTheChannelsThatDidNotAnswer() async throws {
        let channels = channels(24)
        let rss = scripted(channels, answering: 8)
        let target = Counter(12)
        let service = makeService(rss, maxConcurrent: 4, deadline: afterRequests(rss, target))
        _ = await finishing { try await service.feed(channels: channels, forceRefresh: true) }
        await waitUntil { await rss.cancelled.count >= 4 }
        let before = await rss.requested.count
        #expect(before == 12)

        // The network is back: everyone answers, and the time is not up this time.
        for channel in channels.dropFirst(8) {
            await rss.reply(channel.id, with: .videos([video(of: channel, daysAgo: 30)]))
        }
        target.value = .max
        let outcome = await finishing { try await service.feed(channels: channels, forceRefresh: false) }

        let feed = try #require(try outcome?.get())
        #expect(feed.count == 24)
        #expect(Set(await rss.requested.dropFirst(before)) == Set(channels.dropFirst(8).map(\.id)))
        #expect(await rss.requested.count == before + 16)
    }

    @Test func aForcedRefreshAsksTheChannelsThatNeverAnsweredBeforeTheOnesThatDid() async throws {
        // Pull to refresh asks for every channel. With a deadline the order matters: the channels at the end of the
        // list would otherwise never be reached while the same first ones are asked again and again.
        let channels = channels(6)
        let rss = scripted(channels, answering: 2)
        let target = Counter(3)
        let service = makeService(rss, maxConcurrent: 1, deadline: afterRequests(rss, target))
        _ = await finishing { try await service.feed(channels: channels, forceRefresh: true) }
        await waitUntil { await rss.cancelled.contains("UC_2") }
        #expect(await rss.requested == ["UC_0", "UC_1", "UC_2"], "one slot: the third channel is the one that hangs")

        for channel in channels.dropFirst(2) {
            await rss.reply(channel.id, with: .videos([video(of: channel, daysAgo: 30)]))
        }
        target.value = .max
        let outcome = await finishing { try await service.feed(channels: channels, forceRefresh: true) }

        #expect(try #require(try outcome?.get()).count == 6)
        #expect(Array(await rss.requested.dropFirst(3)) == ["UC_2", "UC_3", "UC_4", "UC_5", "UC_0", "UC_1"])
    }

    @Test func aChannelThatAnsweredBeforeTheDeadlineKeepsItsVideosWhenItFailsLater() async throws {
        let channels = channels(3)
        let rss = scripted(channels, answering: 1)
        let target = Counter(2)
        let service = makeService(rss, maxConcurrent: 1, deadline: afterRequests(rss, target))

        let first = try #require(try await finishing { try await service.feed(channels: channels, forceRefresh: true) }?.get())
        #expect(first.map(\.id) == ["v-UC_0"])

        // A later forced refresh in which that channel fails: its videos stay, as they always did.
        await waitUntil { await rss.cancelled.contains("UC_1") }
        await rss.reply("UC_0", with: .failure(.network("blip")))
        for channel in channels.dropFirst() {
            await rss.reply(channel.id, with: .videos([video(of: channel, daysAgo: 30)]))
        }
        target.value = .max
        let second = try #require(try await finishing { try await service.feed(channels: channels, forceRefresh: true) }?.get())
        #expect(second.map(\.id) == ["v-UC_0", "v-UC_1", "v-UC_2"])
    }

    @Test func whenNothingAnswersBeforeTheDeadlineTheRefreshFailsAndTheCachedFeedStays() async throws {
        let channels = channels(3)
        var replies: [String: ScriptedRSS.Reply] = [:]
        for channel in channels { replies[channel.id] = .videos([video(of: channel, daysAgo: 1)]) }
        let rss = ScriptedRSS(replies)
        let target = Counter(.max)
        let service = makeService(rss, maxConcurrent: 2, cache: cacheURL, deadline: afterRequests(rss, target))
        let good = try await service.feed(channels: channels, forceRefresh: true)
        #expect(good.count == 3)

        // The connection stalls: both slots are taken by requests that wait for ever.
        for channel in channels { await rss.reply(channel.id, with: .hang) }
        target.value = await rss.requested.count + 2
        let outcome = await finishing { try await service.feed(channels: channels, forceRefresh: true) }

        let result = try #require(outcome, "the refresh went on waiting for a connection that does not answer")
        guard case .failure(let error) = result, let known = error as? NoSlopError, case .network = known else {
            Issue.record("expected a .network error, got \(result)")
            return
        }
        #expect(await service.cachedFeed() == good)
        #expect(await SubscriptionFeedService(rss: rss, account: nil, cacheURL: cacheURL).cachedFeed() == good)
    }

    @Test func aRealErrorIsReportedInsteadOfTheTimeOutWhenEverythingFails() async throws {
        // One channel answers with an error, the other hangs: nothing worked, and the error that arrived is the news.
        let channels = channels(2)
        let rss = ScriptedRSS(["UC_0": .failure(.http(status: 500)), "UC_1": .hang])
        let service = makeService(rss, maxConcurrent: 1, deadline: afterRequests(rss, Counter(2)))

        let outcome = await finishing { try await service.feed(channels: channels, forceRefresh: true) }

        let result = try #require(outcome)
        guard case .failure(let error) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(error as? NoSlopError == .http(status: 500))
    }

    @Test func aRefreshThatTheCallerCancelsKeepsWhatHadArrived() async throws {
        let channels = channels(4)
        let rss = scripted(channels, answering: 2)
        let service = makeService(rss, maxConcurrent: 1, deadline: .after(.seconds(3_600)))

        let task = Task { try await service.feed(channels: channels, forceRefresh: false) }
        await waitUntil { await rss.requested.count >= 3 }
        task.cancel()
        let result = await task.result
        guard case .failure(let error) = result else {
            Issue.record("expected the refresh to be cancelled, got \(result)")
            return
        }
        #expect(error as? NoSlopError == .cancelled)
        // Half a refresh is not published…
        #expect(await service.cachedFeed().isEmpty)

        // …but the two channels that had answered are not asked again.
        for channel in channels.dropFirst(2) {
            await rss.reply(channel.id, with: .videos([video(of: channel, daysAgo: 30)]))
        }
        await waitUntil { await rss.cancelled.contains("UC_2") }
        let before = await rss.requested.count
        let feed = try #require(try await finishing { try await service.feed(channels: channels, forceRefresh: false) }?.get())
        #expect(feed.count == 4)
        #expect(Array(await rss.requested.dropFirst(before)) == ["UC_2", "UC_3"])
    }

    // MARK: Durations

    @Test func theDurationLookupIsPartOfTheSameDeadline() async throws {
        // The channel answers, but the Data API does not: the feed is handed over at the deadline without durations
        // instead of waiting for the lookup.
        let channel = makeChannel("UC_A")
        let rss = ScriptedRSS(["UC_A": .videos([makeVideo("a1", channel: "UC_A", daysAgo: 1), makeVideo("a2", channel: "UC_A", daysAgo: 2)])])
        let account = ScriptedAccount(durations: ["a1": 61, "a2": 62], hangs: true)
        let target = Counter(1)
        let service = makeService(
            rss, account: account, maxConcurrent: 2,
            deadline: .when { await waitUntil { await account.batches.count >= target.value } }
        )

        let outcome = await finishing { try await service.feed(channels: [channel], forceRefresh: true) }

        let feed = try #require(try outcome?.get(), "the refresh went on waiting for the durations")
        #expect(feed.map(\.id) == ["a1", "a2"])
        #expect(feed.allSatisfy { $0.durationSeconds == nil })

        // The next refresh looks them up again, because nothing was learned.
        await account.hang(false)
        target.value = .max
        let again = try #require(try await finishing { try await service.feed(channels: [channel], forceRefresh: true) }?.get())
        #expect(again.map(\.durationSeconds) == [61, 62])
    }

    @Test func noDurationLookupIsStartedOnceTheTimeIsUp() async throws {
        // The deadline cut the channels short: the time is up, so the Data API is not asked at all.
        let channels = channels(2)
        let rss = scripted(channels, answering: 1)
        let account = ScriptedAccount(durations: ["v-UC_0": 61])
        let service = makeService(rss, account: account, maxConcurrent: 1, deadline: afterRequests(rss, Counter(2)))

        let outcome = await finishing { try await service.feed(channels: channels, forceRefresh: true) }

        let feed = try #require(try outcome?.get())
        #expect(feed.map(\.id) == ["v-UC_0"])
        #expect(feed.first?.durationSeconds == nil)
        #expect(await account.batches.isEmpty)
    }
}

// MARK: - One refresh for everyone who asks at the same time
//
// Home and Subscriptions both bring the uploads up to date, and they do it at the same moment when the app starts on
// one and the viewer goes to the other. A call that asks while a refresh of the same channels is running joins that
// refresh instead of starting another one, so every channel is requested once. The tests keep a refresh running with
// `ScriptedRSS.hold()` and read the service's counters to know that a call has found it, so none of them depends on
// how fast the machine is.

/// True as soon as `condition` holds, false when it still does not after five seconds. A call that never finds the
/// refresh fails its test this way instead of hanging it.
private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    let limit = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < limit {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite final class SubscriptionFeedSharingTests {
    private func channels(_ count: Int) -> [SubscribedChannel] {
        (0..<count).map { makeChannel("UC_\($0)") }
    }

    private func video(of channel: SubscribedChannel, daysAgo: Double) -> VideoSummary {
        makeVideo("v-\(channel.id)", channel: channel.id, daysAgo: daysAgo)
    }

    /// Every channel answers with one video of its own, the first channel's the newest.
    private func answering(_ channels: [SubscribedChannel]) -> ScriptedRSS {
        var replies: [String: ScriptedRSS.Reply] = [:]
        for (index, channel) in channels.enumerated() {
            replies[channel.id] = .videos([video(of: channel, daysAgo: Double(index))])
        }
        return ScriptedRSS(replies)
    }

    /// The first `answering` channels answer at once, every other one hangs.
    private func scripted(_ channels: [SubscribedChannel], answering: Int) -> ScriptedRSS {
        var replies: [String: ScriptedRSS.Reply] = [:]
        for (index, channel) in channels.enumerated() {
            replies[channel.id] = index < answering ? .videos([video(of: channel, daysAgo: Double(index))]) : .hang
        }
        return ScriptedRSS(replies)
    }

    /// The clock stands still, so what a refresh fetched stays fresh for as long as the test runs.
    private func makeService(
        _ rss: ScriptedRSS,
        account: ScriptedAccount? = nil,
        maxConcurrent: Int = 8,
        deadline: FetchDeadline = .after(.seconds(3_600))
    ) -> SubscriptionFeedService {
        SubscriptionFeedService(
            rss: rss, account: account, cacheURL: nil, maxConcurrent: maxConcurrent,
            channelCacheTTL: 900, fetchDeadline: deadline, now: { t0 }
        )
    }

    /// A call that is under way when this returns and ends when its refresh does.
    private func call(
        _ service: SubscriptionFeedService, _ channels: [SubscribedChannel], forced: Bool = false
    ) -> Task<[VideoSummary], any Error> {
        Task { try await service.feed(channels: channels, forceRefresh: forced) }
    }

    // MARK: Sharing

    @Test func twoCallsAtTheSameTimeRequestEveryChannelOnce() async throws {
        let channels = channels(6)
        let rss = answering(channels)
        let service = makeService(rss, maxConcurrent: 3)
        await rss.hold()

        let first = call(service, channels)
        _ = await eventually { await rss.requested.count >= 1 }
        let second = call(service, channels)
        let joined = await eventually { await service.callsJoined == 1 }
        await rss.release()

        let firstFeed = try await first.value
        let secondFeed = try await second.value
        #expect(joined, "the second call started a refresh of its own instead of joining the one that was running")
        #expect(firstFeed.count == 6)
        #expect(secondFeed == firstFeed)
        #expect(await rss.requested.sorted() == channels.map(\.id).sorted())
        #expect(await service.refreshesStarted == 1)
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func aCallJoinsARefreshThatAsksForAllItsChannels(firstForced: Bool, secondForced: Bool) async throws {
        // Nothing has been fetched yet, so the refresh that is running asks for every channel, whichever way it was
        // asked for: it is as good as a forced one for a forced call.
        let channels = channels(4)
        let rss = answering(channels)
        let service = makeService(rss, maxConcurrent: 2)
        await rss.hold()

        let first = call(service, channels, forced: firstForced)
        _ = await eventually { await rss.requested.count >= 1 }
        let second = call(service, channels, forced: secondForced)
        let joined = await eventually { await service.callsJoined == 1 }
        await rss.release()

        let firstFeed = try await first.value
        let secondFeed = try await second.value
        #expect(joined)
        #expect(secondFeed == firstFeed)
        #expect(await rss.requested.sorted() == channels.map(\.id).sorted())
        #expect(await service.refreshesStarted == 1)
    }

    @Test func aForcedCallIsNotServedByARefreshThatLeftOutFreshChannels() async throws {
        let channels = channels(2)
        let rss = answering(channels)
        let service = makeService(rss)
        // The first channel is fresh from now on.
        _ = try await service.feed(channels: [channels[0]], forceRefresh: false)
        #expect(await rss.requested == ["UC_0"])

        await rss.hold()
        let first = call(service, channels)  // asks for the second channel only
        _ = await eventually { await rss.requested.count >= 2 }
        let second = call(service, channels, forced: true)  // has to ask for both again
        let started = await eventually { await service.refreshesStarted == 3 }
        await rss.release()

        let firstFeed = try await first.value
        let secondFeed = try await second.value
        #expect(started, "the forced call was served by a refresh that had not asked for the first channel")
        #expect(await service.callsJoined == 0)
        #expect(await rss.requested.sorted() == ["UC_0", "UC_0", "UC_1", "UC_1"])
        #expect(firstFeed.count == 2)
        #expect(secondFeed.count == 2)
    }

    @Test func aCallForFewerChannelsJoinsAndGetsOnlyItsOwnVideos() async throws {
        let channels = channels(3)
        let rss = answering(channels)
        let service = makeService(rss)
        await rss.hold()

        let first = call(service, channels)
        _ = await eventually { await rss.requested.count >= 1 }
        let second = call(service, Array(channels.prefix(2)))
        let joined = await eventually { await service.callsJoined == 1 }
        await rss.release()

        let firstFeed = try await first.value
        let secondFeed = try await second.value
        #expect(joined)
        #expect(firstFeed.map(\.id) == ["v-UC_0", "v-UC_1", "v-UC_2"])
        #expect(secondFeed.map(\.id) == ["v-UC_0", "v-UC_1"])
        #expect(await rss.requested.sorted() == channels.map(\.id).sorted())
    }

    @Test func aCallForMoreChannelsStartsARefreshOfItsOwnAndGetsAllOfThem() async throws {
        let channels = channels(3)
        let rss = answering(channels)
        let service = makeService(rss)
        await rss.hold()

        let first = call(service, Array(channels.prefix(2)))
        _ = await eventually { await rss.requested.count >= 1 }
        let second = call(service, channels)
        let started = await eventually { await service.refreshesStarted == 2 }
        await rss.release()

        let firstFeed = try await first.value
        let secondFeed = try await second.value
        #expect(started, "a refresh that does not cover the channels cannot serve the call")
        #expect(await service.callsJoined == 0)
        #expect(firstFeed.map(\.id) == ["v-UC_0", "v-UC_1"])
        #expect(secondFeed.map(\.id) == ["v-UC_0", "v-UC_1", "v-UC_2"])
    }

    @Test func aCallAfterTheRefreshHasEndedJoinsNothing() async throws {
        let channels = channels(3)
        let rss = answering(channels)
        let service = makeService(rss)

        let first = try await service.feed(channels: channels, forceRefresh: false)
        let second = try await service.feed(channels: channels, forceRefresh: false)

        #expect(second == first)
        #expect(await service.callsJoined == 0)
        #expect(await rss.requested.count == 3, "the channels are fresh, so the second call asks for none of them")
    }

    @Test func everyoneWhoSharedARefreshGetsItsError() async throws {
        let channels = channels(3)
        let rss = ScriptedRSS(Dictionary(uniqueKeysWithValues: channels.map { ($0.id, ScriptedRSS.Reply.failure(.network("offline"))) }))
        let service = makeService(rss)
        await rss.hold()

        let first = call(service, channels)
        _ = await eventually { await rss.requested.count >= 1 }
        let second = call(service, channels)
        let joined = await eventually { await service.callsJoined == 1 }
        await rss.release()

        let results = [await first.result, await second.result]
        #expect(joined)
        for result in results {
            guard case .failure(let error) = result else {
                Issue.record("expected the error of the channels, got \(result)")
                continue
            }
            #expect(error as? NoSlopError == .network("offline"))
        }
        #expect(await rss.requested.sorted() == channels.map(\.id).sorted())
    }

    @Test func callsThatShareARefreshShareTheDurationLookup() async throws {
        let channels = channels(2)
        let rss = answering(channels)
        let account = ScriptedAccount(durations: ["v-UC_0": 60, "v-UC_1": 120])
        let service = makeService(rss, account: account)
        await rss.hold()

        let first = call(service, channels)
        _ = await eventually { await rss.requested.count >= 1 }
        let second = call(service, channels)
        let joined = await eventually { await service.callsJoined == 1 }
        await rss.release()

        let firstFeed = try await first.value
        let secondFeed = try await second.value
        #expect(joined)
        #expect(firstFeed.map(\.durationSeconds) == [60, 120])
        #expect(secondFeed == firstFeed)
        #expect(await account.batches.count == 1, "one lookup for both calls")
    }

    // MARK: Cancelling

    @Test func aCallThatIsCancelledLeavesTheRefreshToTheOthers() async throws {
        let channels = channels(4)
        let rss = answering(channels)
        let service = makeService(rss, maxConcurrent: 2)
        await rss.hold()

        let first = call(service, channels)
        _ = await eventually { await rss.requested.count >= 2 }
        let second = call(service, channels)
        let joined = await eventually { await service.callsJoined == 1 }

        first.cancel()
        // Whoever gave up is told at once, while the requests are still held.
        let firstResult = await first.result
        await rss.release()
        let secondFeed = try await second.value

        #expect(joined)
        if case .failure(let error) = firstResult {
            #expect(error as? NoSlopError == .cancelled)
        } else {
            Issue.record("expected the cancelled call to end with .cancelled, got \(firstResult)")
        }
        #expect(secondFeed.count == 4, "the other call still gets the whole refresh")
        #expect(await rss.cancelled.isEmpty, "no request was cancelled for the sake of the caller that left")
        #expect(await rss.requested.sorted() == channels.map(\.id).sorted())
    }

    @Test func theRefreshIsCancelledWhenTheLastCallLeaves() async throws {
        let channels = channels(4)
        let rss = answering(channels)
        let service = makeService(rss, maxConcurrent: 2)
        await rss.hold()

        let first = call(service, channels)
        _ = await eventually { await rss.requested.count >= 2 }
        let second = call(service, channels)
        let joined = await eventually { await service.callsJoined == 1 }

        first.cancel()
        _ = await first.result
        #expect(await rss.cancelled.isEmpty, "one call is still waiting for the requests")
        second.cancel()
        _ = await second.result

        // Nobody is waiting any more: the two requests that were under way are cancelled and no other is started.
        let stopped = await eventually { await rss.cancelled.count == 2 }
        #expect(joined)
        #expect(stopped)
        #expect(Set(await rss.cancelled) == ["UC_0", "UC_1"])
        #expect(await rss.requested.count == 2)

        // The next call starts over and gets everything.
        await rss.release()
        let feed = try await call(service, channels).value
        #expect(feed.count == 4)
    }

    // MARK: The time limit

    @Test func theTimeLimitEndsASharedRefreshForEveryone() async throws {
        // Two slots. The first three channels answer; then both slots are taken by requests that never do. The time is
        // up once five requests have been made, which the test only says after the second call has joined.
        let channels = channels(8)
        let rss = scripted(channels, answering: 3)
        let target = Counter(.max)
        let service = makeService(rss, maxConcurrent: 2, deadline: afterRequests(rss, target))

        let first = call(service, channels)
        _ = await eventually { await rss.requested.count == 5 }
        let second = call(service, channels)
        let joined = await eventually { await service.callsJoined == 1 }
        target.value = 5

        let firstOutcome = await finishing { try await first.value }
        let secondOutcome = await finishing { try await second.value }

        #expect(joined)
        let firstFeed = try #require(try firstOutcome?.get(), "the first call went on waiting for the channels that do not answer")
        let secondFeed = try #require(try secondOutcome?.get(), "the second call went on waiting for the channels that do not answer")
        #expect(firstFeed.map(\.id) == ["v-UC_0", "v-UC_1", "v-UC_2"])
        #expect(secondFeed == firstFeed)
        #expect(await rss.requested.count == 5, "every channel was asked once, and none after the time was up")
        await waitUntil { await rss.cancelled.count >= 2 }
        #expect(Set(await rss.cancelled) == ["UC_3", "UC_4"])
    }
}
