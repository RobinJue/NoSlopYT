import Foundation
import Synchronization

// Mock implementations of every service protocol, returning `SampleData` after an artificial delay.
// They back SwiftUI previews and `-mockServices YES` launches, and give UI work something to talk to while the
// real implementations are built. Every mock is `public` and `Sendable`.
//
// Continuation tokens are plain strings of the form "mock-<kind>:<...>" so each paging call is stateless.

// MARK: - Delay

private enum MockDelay {
    /// Sleeps for `delay`. A cancelled task throws `NoSlopError.cancelled`, like the real network clients do.
    static func wait(_ delay: Duration) async throws {
        guard delay > .zero else { return }
        do {
            try await Task.sleep(for: delay)
        } catch {
            throw NoSlopError.cancelled
        }
    }

    /// For protocol methods that cannot throw.
    static func waitQuietly(_ delay: Duration) async {
        guard delay > .zero else { return }
        try? await Task.sleep(for: delay)
    }
}

private func newestFirst(_ videos: [VideoSummary]) -> [VideoSummary] {
    videos.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
}

// MARK: - Connection

/// The connection of a mock run, as a switch. While it is off, the mocks that were given it fail the way the real
/// services do without a network (`NoSlopError.network`), and come back when it is turned on. Simulator checks of the
/// offline screens use it (`-mockOffline`); a mock that was not given one is always online.
public final class MockConnection: Sendable {
    private let online: Mutex<Bool>

    public init(isOnline: Bool = true) {
        online = Mutex(isOnline)
    }

    public var isOnline: Bool {
        get { online.withLock { $0 } }
        set { online.withLock { $0 = newValue } }
    }

    func requireOnline() throws {
        if !isOnline {
            throw NoSlopError.network("The mock connection is off.")
        }
    }
}

// MARK: - YouTube service

/// `YouTubeService` over `SampleData`.
///
/// - Search ignores the query text (it always finds the sample videos, with a channel and a playlist mixed in)
///   but honours the filter's type, sort, duration and upload date. Pages hold 10 items.
/// - `resolve(url:)` understands the same links the real `YouTubeURL` does, including `noslop://watch?v=…`,
///   `noslop://channel/<id>`, `noslop://playlist/<id>` and `noslop://search?q=…`, and maps any `@handle` to Blender.
public struct MockYouTubeService: YouTubeService {
    private let delay: Duration
    private let connection: MockConnection?

    /// - Parameter connection: when given and off, every call fails with `NoSlopError.network`.
    public init(delay: Duration = .milliseconds(300), connection: MockConnection? = nil) {
        self.delay = delay
        self.connection = connection
    }

    /// What every call starts with: the connection it needs, then the time the answer takes.
    private func reachNetwork() async throws {
        try connection?.requireOnline()
        try await MockDelay.wait(delay)
    }

    private static let pageSize = 10

    // MARK: Search

    public func search(query: String, filter: SearchFilter) async throws -> Page<SearchItem> {
        try await reachNetwork()
        return Self.page(of: Self.results(for: filter), cursor: SearchCursor(filter: filter, page: 0))
    }

    public func searchMore(continuation: String) async throws -> Page<SearchItem> {
        try await reachNetwork()
        guard let cursor = SearchCursor(token: continuation) else { return Page() }
        return Self.page(of: Self.results(for: cursor.filter), cursor: cursor)
    }

    public func suggestions(for query: String) async throws -> [String] {
        try await reachNetwork()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return [q, "\(q) tutorial", "\(q) for beginners", "\(q) 2026", "\(q) full course", "\(q) tips and tricks"]
    }

    private struct SearchCursor {
        let filter: SearchFilter
        let page: Int

        init(filter: SearchFilter, page: Int) {
            self.filter = filter
            self.page = page
        }

        init?(token: String) {
            let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6, parts[0] == "mock-search",
                  let type = SearchType(rawValue: parts[1]),
                  let sort = SearchSort(rawValue: parts[2]),
                  let duration = SearchDuration(rawValue: parts[3]),
                  let uploadDate = SearchUploadDate(rawValue: parts[4]),
                  let page = Int(parts[5]) else { return nil }
            self.filter = SearchFilter(type: type, sort: sort, duration: duration, uploadDate: uploadDate)
            self.page = page
        }

        var token: String {
            ["mock-search", filter.type.rawValue, filter.sort.rawValue, filter.duration.rawValue,
             filter.uploadDate.rawValue, String(page)].joined(separator: ":")
        }
    }

    private static func page(of items: [SearchItem], cursor: SearchCursor) -> Page<SearchItem> {
        let start = cursor.page * pageSize
        guard start < items.count else { return Page() }
        let end = min(items.count, start + pageSize)
        let next = end < items.count ? SearchCursor(filter: cursor.filter, page: cursor.page + 1).token : nil
        return Page(items: Array(items[start..<end]), continuation: next)
    }

    private static func results(for filter: SearchFilter) -> [SearchItem] {
        var videos = SampleData.videos

        switch filter.duration {
        case .any: break
        case .short: videos = videos.filter { ($0.durationSeconds ?? .max) < 240 }
        case .medium: videos = videos.filter { (240...1200).contains($0.durationSeconds ?? 0) }
        case .long: videos = videos.filter { ($0.durationSeconds ?? 0) > 1200 }
        }

        let ageLimit: TimeInterval?
        switch filter.uploadDate {
        case .any: ageLimit = nil
        case .lastHour: ageLimit = 3_600
        case .today: ageLimit = 86_400
        case .thisWeek: ageLimit = 7 * 86_400
        case .thisMonth: ageLimit = 30 * 86_400
        case .thisYear: ageLimit = 365 * 86_400
        }
        if let ageLimit {
            let cutoff = Date().addingTimeInterval(-ageLimit)
            videos = videos.filter { ($0.publishedAt ?? .distantPast) >= cutoff }
        }

        switch filter.sort {
        case .relevance: break
        case .uploadDate: videos = newestFirst(videos)
        case .viewCount: videos.sort { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }
        }

        switch filter.type {
        case .video:
            return videos.map(SearchItem.video)
        case .channel:
            return SampleData.channels.map(SearchItem.channel)
        case .playlist:
            return SampleData.playlists.map(SearchItem.playlist)
        case .all:
            // Duration and upload date only apply to videos, as on YouTube.
            guard filter.duration == .any, filter.uploadDate == .any else { return videos.map(SearchItem.video) }
            var items: [SearchItem] = []
            for (index, video) in videos.enumerated() {
                items.append(.video(video))
                if index == 2 { items.append(.channel(SampleData.blenderGuru)) }
                if index == 5 { items.append(.playlist(SampleData.playlist)) }
            }
            return items
        }
    }

    // MARK: Watch page

    public func videoDetails(id: String) async throws -> VideoDetails {
        try await reachNetwork()
        let video = SampleData.video(id: id) ?? VideoSummary(
            id: id,
            title: "Sample video",
            channel: SampleData.blender.ref,
            thumbnails: VideoSummary.defaultThumbnails(for: id)
        )
        return SampleData.details(for: video)
    }

    public func moreRelated(continuation: String) async throws -> Page<VideoSummary> {
        try await reachNetwork()
        // "mock-related:<videoID>:<page>"
        let parts = continuation.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "mock-related", let page = Int(parts[2]) else { return Page() }
        let related = SampleData.videos.filter { $0.id != parts[1] }
        let start = page * SampleData.relatedPageSize
        guard start < related.count else { return Page() }
        let end = min(related.count, start + SampleData.relatedPageSize)
        return Page(
            items: Array(related[start..<end]),
            continuation: end < related.count ? "mock-related:\(parts[1]):\(page + 1)" : nil
        )
    }

    public func comments(continuation: String) async throws -> CommentsPage {
        try await reachNetwork()
        let parts = continuation.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "mock-replies":
            return CommentsPage(comments: SampleData.replies)
        case "mock-comments-more":
            return CommentsPage(comments: SampleData.moreComments)
        case "mock-comments":
            // "mock-comments:<videoID>:<top|new>"
            let videoID = parts.count > 1 ? parts[1] : ""
            let newest = parts.count > 2 && parts[2] == "new"
            return CommentsPage(
                comments: newest ? Array(SampleData.comments.reversed()) : SampleData.comments,
                continuation: "mock-comments-more:\(videoID)",
                totalCountText: "5,222 Comments",
                sortOptions: [
                    CommentSortOption(title: "Top", continuation: "mock-comments:\(videoID):top", isSelected: !newest),
                    CommentSortOption(title: "Newest", continuation: "mock-comments:\(videoID):new", isSelected: newest),
                ]
            )
        default:
            return CommentsPage()
        }
    }

    // MARK: Channels

    public func channel(id: String) async throws -> ChannelPage {
        try await reachNetwork()
        let summary = SampleData.channel(id: id) ?? ChannelSummary(
            id: id,
            name: "Sample channel",
            avatarURL: SampleData.blender.avatarURL,
            subscriberCountText: "12K subscribers",
            videoCountText: "48 videos"
        )
        let header = ChannelHeader(
            id: summary.id,
            name: summary.name,
            handle: summary.handle,
            avatarURL: summary.avatarURL,
            bannerURL: SampleData.channelBannerURL,
            subscriberCountText: summary.subscriberCountText,
            videoCountText: summary.videoCountText,
            description: summary.descriptionSnippet
        )
        return ChannelPage(
            header: header,
            availableTabs: ChannelTabKind.allCases,
            videos: Page(items: Self.channelVideos(id).map(SearchItem.video))
        )
    }

    public func channelTab(channelID: String, tab: ChannelTabKind) async throws -> Page<SearchItem> {
        try await reachNetwork()
        switch tab {
        case .videos:
            return Page(items: Self.channelVideos(channelID).map(SearchItem.video))
        case .live:
            return Page()
        case .playlists:
            return Page(items: SampleData.playlists.filter { $0.channel?.id == channelID }.map(SearchItem.playlist))
        }
    }

    public func channelMore(continuation: String) async throws -> Page<SearchItem> {
        try await reachNetwork()
        return Page()
    }

    /// The channel's sample uploads; an unknown channel gets the first few non-Short sample videos.
    private static func channelVideos(_ channelID: String) -> [VideoSummary] {
        let own = SampleData.videos(forChannel: channelID)
        return own.isEmpty ? Array(SampleData.videos.filter { !$0.isShort }.prefix(6)) : own
    }

    // MARK: Playlists

    public func playlist(id: String) async throws -> PlaylistPage {
        try await reachNetwork()
        let (info, videos) = Self.playlistContent(id)
        let first = Array(videos.prefix(Self.pageSize))
        return PlaylistPage(
            info: info,
            description: "A sample playlist.",
            videos: Page(items: first, continuation: videos.count > first.count ? "mock-playlist:\(id):1" : nil)
        )
    }

    public func playlistMore(continuation: String) async throws -> Page<VideoSummary> {
        try await reachNetwork()
        // "mock-playlist:<playlistID>:<page>"
        let parts = continuation.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "mock-playlist", let page = Int(parts[2]) else { return Page() }
        let videos = Self.playlistContent(parts[1]).videos
        let start = page * Self.pageSize
        guard start < videos.count else { return Page() }
        let end = min(videos.count, start + Self.pageSize)
        return Page(
            items: Array(videos[start..<end]),
            continuation: end < videos.count ? "mock-playlist:\(parts[1]):\(page + 1)" : nil
        )
    }

    /// The Blender playlist shows three Blender uploads; every other id gets the 14-video tutorial series.
    private static func playlistContent(_ id: String) -> (info: PlaylistSummary, videos: [VideoSummary]) {
        if id == SampleData.blenderPlaylist.id {
            return (SampleData.blenderPlaylist, Array(SampleData.videos(forChannel: SampleData.blender.id).prefix(3)))
        }
        var info = SampleData.playlist
        info.id = id
        return (info, SampleData.playlistVideos)
    }

    // MARK: URLs

    public func resolve(url: URL) async throws -> ResolvedURL? {
        try await reachNetwork()
        return MockURLResolver.resolve(url)
    }
}

/// Link recognition for the mock service (the real one lives in `YouTubeURL`, Task 2).
private enum MockURLResolver {
    static func resolve(_ url: URL) -> ResolvedURL? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> String? {
            components?.queryItems?.first { $0.name == name }?.value
        }
        func startSeconds() -> Int? {
            (query("t") ?? query("start")).flatMap(seconds(from:))
        }
        let parts = url.pathComponents.filter { $0 != "/" }

        if scheme == "noslop" {
            switch url.host?.lowercased() {
            case "watch": return query("v").map { .video(id: $0, startSeconds: startSeconds()) }
            case "channel": return parts.first.map { .channel(id: $0) }
            case "playlist": return (parts.first ?? query("list")).map { .playlist(id: $0) }
            case "search": return query("q").map { .search(query: $0) }
            default: return nil
            }
        }

        guard scheme == "http" || scheme == "https", let host = url.host?.lowercased(), isYouTube(host) else { return nil }
        if host == "youtu.be" {
            return parts.first.map { .video(id: $0, startSeconds: startSeconds()) }
        }
        switch parts.first {
        case "watch":
            if let id = query("v") { return .video(id: id, startSeconds: startSeconds()) }
            return query("list").map { .playlist(id: $0) }
        case "shorts", "live", "embed":
            return parts.dropFirst().first.map { .video(id: $0, startSeconds: nil) }
        case "channel":
            return parts.dropFirst().first.map { .channel(id: $0) }
        case "playlist":
            return query("list").map { .playlist(id: $0) }
        case let first? where first.hasPrefix("@"):
            // A handle needs the network in real life; the mock maps every handle to a sample channel.
            return .channel(id: SampleData.blender.id)
        default:
            return nil
        }
    }

    private static func isYouTube(_ host: String) -> Bool {
        host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com")
    }

    /// "42", "42s", "1m5s", "1h2m3s" -> seconds.
    private static func seconds(from text: String) -> Int? {
        if let plain = Int(text) { return plain }
        var total = 0
        var number = 0
        var sawUnit = false
        for character in text.lowercased() {
            if character.isASCII, let digit = character.wholeNumberValue {
                number = number * 10 + digit
                continue
            }
            switch character {
            case "h": total += number * 3_600
            case "m": total += number * 60
            case "s": total += number
            default: return nil
            }
            number = 0
            sawUnit = true
        }
        return sawUnit ? total : nil
    }
}

// MARK: - Streams, captions, RSS

/// `StreamResolving` that returns Apple's bipbop HLS stream for every video, with no downloadable formats.
public struct MockStreamResolver: StreamResolving {
    private let delay: Duration
    private let connection: MockConnection?

    /// - Parameter connection: when given and off, every call fails with `NoSlopError.network`.
    public init(delay: Duration = .milliseconds(300), connection: MockConnection? = nil) {
        self.delay = delay
        self.connection = connection
    }

    public func streamInfo(videoID: String) async throws -> StreamInfo {
        try connection?.requireOnline()
        try await MockDelay.wait(delay)
        return SampleData.streamInfo(for: videoID)
    }
}

/// `CaptionsProviding` that returns the same few cues for every track.
public struct MockCaptions: CaptionsProviding {
    private let delay: Duration
    private let connection: MockConnection?

    /// - Parameter connection: when given and off, every call fails with `NoSlopError.network`.
    public init(delay: Duration = .milliseconds(300), connection: MockConnection? = nil) {
        self.delay = delay
        self.connection = connection
    }

    public func cues(for track: CaptionTrack) async throws -> [CaptionCue] {
        try connection?.requireOnline()
        try await MockDelay.wait(delay)
        return SampleData.captionCues
    }
}

/// `RSSFeedFetching` that returns the channel's sample uploads, newest first.
public struct MockRSSFeed: RSSFeedFetching {
    private let delay: Duration

    public init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    public func latestVideos(channelID: String) async throws -> [VideoSummary] {
        try await MockDelay.wait(delay)
        return SampleData.videos(forChannel: channelID)
    }
}

// MARK: - Google account

/// `GoogleAuthProviding` that signs in instantly as "You" without showing any web page.
public actor MockAuth: GoogleAuthProviding {
    private let delay: Duration
    private var account: GoogleAccount?

    /// - Parameter signedIn: start with the mock account already signed in.
    public init(delay: Duration = .milliseconds(300), signedIn: Bool = false) {
        self.delay = delay
        self.account = signedIn ? Self.mockAccount : nil
    }

    private static let mockAccount = GoogleAccount(id: "mock", email: "you@example.com", name: "You")

    public func currentAccount() async -> GoogleAccount? {
        account
    }

    public func signIn(clientID: String, authenticator: any WebAuthenticating) async throws -> GoogleAccount {
        try await MockDelay.wait(delay)
        account = Self.mockAccount
        return Self.mockAccount
    }

    public func signOut() async {
        account = nil
    }

    public func accessToken() async throws -> String {
        guard account != nil else { throw NoSlopError.notSignedIn }
        return "mock-access-token"
    }
}

/// `YouTubeAccountService` that remembers subscriptions and ratings in memory. It starts with Blender and
/// Blender Guru subscribed.
public actor MockAccountService: YouTubeAccountService {
    private let delay: Duration
    private var subscribed: [SubscribedChannel]
    private var ratings: [String: VideoRating] = [:]

    public init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
        self.subscribed = [SampleData.blender, SampleData.blenderGuru].map { channel in
            SubscribedChannel(
                id: channel.id,
                name: channel.name,
                avatarURL: channel.avatarURL,
                source: .google(subscriptionID: "mock-sub-\(channel.id)"),
                subscribedAt: Date()
            )
        }
    }

    public func subscriptions() async throws -> [SubscribedChannel] {
        try await MockDelay.wait(delay)
        return subscribed
    }

    public func subscribe(channelID: String) async throws -> String {
        try await MockDelay.wait(delay)
        let subscriptionID = "mock-sub-\(channelID)"
        if !subscribed.contains(where: { $0.id == channelID }) {
            let channel = SampleData.channel(id: channelID)
            subscribed.append(
                SubscribedChannel(
                    id: channelID,
                    name: channel?.name ?? channelID,
                    avatarURL: channel?.avatarURL,
                    source: .google(subscriptionID: subscriptionID),
                    subscribedAt: Date()
                )
            )
        }
        return subscriptionID
    }

    public func unsubscribe(subscriptionID: String) async throws {
        try await MockDelay.wait(delay)
        subscribed.removeAll { channel in
            if case .google(let id) = channel.source { return id == subscriptionID }
            return false
        }
    }

    public func myPlaylists() async throws -> [PlaylistSummary] {
        try await MockDelay.wait(delay)
        return SampleData.playlists
    }

    /// Ten videos on the first page, the rest on "page2".
    public func playlistItems(playlistID: String, pageToken: String?) async throws -> Page<VideoSummary> {
        try await MockDelay.wait(delay)
        let videos = SampleData.playlistVideos
        return pageToken == nil
            ? Page(items: Array(videos.prefix(10)), continuation: videos.count > 10 ? "page2" : nil)
            : Page(items: Array(videos.dropFirst(10)))
    }

    /// Four videos on the first page, the rest on "page2".
    public func likedVideos(pageToken: String?) async throws -> Page<VideoSummary> {
        try await MockDelay.wait(delay)
        let videos = SampleData.videos.filter { !$0.isShort }.prefix(7)
        return pageToken == nil
            ? Page(items: Array(videos.prefix(4)), continuation: "page2")
            : Page(items: Array(videos.dropFirst(4)))
    }

    public func rating(videoID: String) async throws -> VideoRating {
        try await MockDelay.wait(delay)
        return ratings[videoID] ?? .none
    }

    public func rate(videoID: String, rating: VideoRating) async throws {
        try await MockDelay.wait(delay)
        ratings[videoID] = rating
    }

    public func addToPlaylist(videoID: String, playlistID: String) async throws {
        try await MockDelay.wait(delay)
    }

    public func durations(videoIDs: [String]) async throws -> [String: Int] {
        try await MockDelay.wait(delay)
        var result: [String: Int] = [:]
        for id in videoIDs {
            if let seconds = SampleData.video(id: id)?.durationSeconds { result[id] = seconds }
        }
        return result
    }
}

// MARK: - SponsorBlock and DeArrow

/// `SponsorBlockProviding` that returns the two sample segments (sponsor 30-45 s, self-promotion 120-130 s)
/// for every video.
public struct MockSponsorBlock: SponsorBlockProviding {
    private let delay: Duration
    private let failures: FailureBudget?
    private let connection: MockConnection?

    /// - Parameter connection: when given and off, every lookup fails with `NoSlopError.network`.
    public init(delay: Duration = .milliseconds(300), connection: MockConnection? = nil) {
        self.delay = delay
        self.failures = nil
        self.connection = connection
    }

    /// A service with a bad moment, for checking that the player retries: the first `failingFirst` lookups (counted
    /// across copies of the mock) throw a network error, the following ones answer. Zero or less never fails.
    public init(delay: Duration = .milliseconds(300), failingFirst: Int, connection: MockConnection? = nil) {
        self.delay = delay
        self.failures = failingFirst > 0 ? FailureBudget(failingFirst) : nil
        self.connection = connection
    }

    public func segments(videoID: String) async throws -> [SponsorSegment] {
        try connection?.requireOnline()
        try await MockDelay.wait(delay)
        if failures?.takeOne() == true {
            throw NoSlopError.network("SponsorBlock is having a bad moment.")
        }
        return SampleData.segments
    }

    /// How many lookups are still to fail; shared by the copies of the mock.
    private final class FailureBudget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int

        init(_ count: Int) {
            remaining = count
        }

        /// Whether a failure is still owed; uses it up.
        func takeOne() -> Bool {
            lock.withLock {
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
        }
    }
}

/// `DeArrowProviding` that has a better title only for `dQw4w9WgXcQ`.
public struct MockDeArrow: DeArrowProviding {
    private let delay: Duration

    public init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    public func betterTitle(videoID: String) async -> String? {
        await MockDelay.waitQuietly(delay)
        return videoID == "dQw4w9WgXcQ" ? SampleData.betterTitleForRickroll : nil
    }
}

// MARK: - Feeds

/// `SubscriptionFeedProviding` that returns the sample uploads of the given channels, newest first.
///
/// Like the real service it remembers the feed it built last: `cachedFeed()` is what the last `feed(...)` returned, or
/// what the mock was started with (`cached`, the feed on disk from an earlier session), and empty before that.
public struct MockSubscriptionFeed: SubscriptionFeedProviding {
    private let delay: Duration
    private let connection: MockConnection?
    private let remembered: Remembered

    /// - Parameters:
    ///   - connection: when given and off, `feed(...)` fails with `NoSlopError.network` and the cache stays as it is.
    ///   - cached: the feed `cachedFeed()` starts with, as if an earlier session had left it on disk.
    public init(delay: Duration = .milliseconds(300), connection: MockConnection? = nil, cached: [VideoSummary] = []) {
        self.delay = delay
        self.connection = connection
        self.remembered = Remembered(cached)
    }

    public func cachedFeed() async -> [VideoSummary] {
        remembered.feed
    }

    public func feed(channels: [SubscribedChannel], forceRefresh: Bool) async throws -> [VideoSummary] {
        try connection?.requireOnline()
        try await MockDelay.wait(delay)
        let ids = Set(channels.map(\.id))
        let feed = newestFirst(SampleData.videos.filter { video in
            video.channel.map { ids.contains($0.id) } ?? false
        })
        remembered.feed = feed
        return feed
    }

    private final class Remembered: Sendable {
        private let state: Mutex<[VideoSummary]>

        init(_ feed: [VideoSummary]) {
            state = Mutex(feed)
        }

        var feed: [VideoSummary] {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }
}

/// `HomeFeedProviding` that always has something to show: "Continue watching" from the history (same rules as the
/// real service) and "For you" from the subscription videos followed by the sample videos, minus what was watched.
///
/// Without a connection (`MockConnection` off) it behaves like the real service that cannot reach YouTube: "For you"
/// is the subscription videos that were not watched, and a history to ask about makes the feed `relatedUnavailable`.
public struct MockHomeFeed: HomeFeedProviding {
    private let delay: Duration
    private let connection: MockConnection?

    public init(delay: Duration = .milliseconds(300), connection: MockConnection? = nil) {
        self.delay = delay
        self.connection = connection
    }

    public func homeFeed(history: [HistoryEntry], subscriptionVideos: [VideoSummary]) async -> HomeFeed {
        await MockDelay.waitQuietly(delay)
        let isOnline = connection?.isOnline ?? true
        var seen = Set(history.map(\.id))
        var forYou: [VideoSummary] = []
        for video in isOnline ? subscriptionVideos + SampleData.videos : subscriptionVideos where seen.insert(video.id).inserted {
            forYou.append(video)
        }
        return HomeFeed(
            continueWatching: HomeFeed.continueWatching(in: history),
            forYou: Array(forYou.prefix(60)),
            relatedUnavailable: !isOnline && history.contains { !$0.video.isShort }
        )
    }
}
