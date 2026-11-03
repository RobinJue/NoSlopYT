import Foundation

// The seams between the app, the real implementations and the mocks. Every service is `Sendable` so the UI can
// hold it in `let` properties and call it from any task.

/// Anonymous YouTube access through InnerTube: search, watch page, comments, channels, playlists, URL resolving.
public protocol YouTubeService: Sendable {
    func search(query: String, filter: SearchFilter) async throws -> Page<SearchItem>
    func searchMore(continuation: String) async throws -> Page<SearchItem>
    func suggestions(for query: String) async throws -> [String]
    func videoDetails(id: String) async throws -> VideoDetails
    func moreRelated(continuation: String) async throws -> Page<VideoSummary>
    func comments(continuation: String) async throws -> CommentsPage
    func channel(id: String) async throws -> ChannelPage
    func channelTab(channelID: String, tab: ChannelTabKind) async throws -> Page<SearchItem>
    func channelMore(continuation: String) async throws -> Page<SearchItem>
    func playlist(id: String) async throws -> PlaylistPage
    func playlistMore(continuation: String) async throws -> Page<VideoSummary>
    func resolve(url: URL) async throws -> ResolvedURL?
}

/// Resolves the playable/downloadable sources of a video (the `player` endpoint).
public protocol StreamResolving: Sendable {
    func streamInfo(videoID: String) async throws -> StreamInfo
}

public protocol CaptionsProviding: Sendable {
    func cues(for track: CaptionTrack) async throws -> [CaptionCue]
}

/// Latest uploads of a channel from its public RSS feed.
public protocol RSSFeedFetching: Sendable {
    func latestVideos(channelID: String) async throws -> [VideoSummary]
}

/// Shows a web sign-in page and returns the URL it redirected to. Implemented by the app with
/// `ASWebAuthenticationSession`.
@MainActor
public protocol WebAuthenticating: AnyObject, Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

public protocol TokenStoring: Sendable {
    func load() throws -> StoredCredentials?
    func save(_ credentials: StoredCredentials) throws
    func clear() throws
}

public protocol GoogleAuthProviding: Sendable {
    func currentAccount() async -> GoogleAccount?
    func signIn(clientID: String, authenticator: any WebAuthenticating) async throws -> GoogleAccount
    func signOut() async
    /// A valid access token, refreshed when needed. Throws `.notSignedIn` when there are no credentials.
    func accessToken() async throws -> String
}

/// The signed-in user's YouTube account, through the official Data API v3.
public protocol YouTubeAccountService: Sendable {
    func subscriptions() async throws -> [SubscribedChannel]
    /// Returns the new subscription id.
    func subscribe(channelID: String) async throws -> String
    func unsubscribe(subscriptionID: String) async throws
    func myPlaylists() async throws -> [PlaylistSummary]
    func playlistItems(playlistID: String, pageToken: String?) async throws -> Page<VideoSummary>
    func likedVideos(pageToken: String?) async throws -> Page<VideoSummary>
    func rating(videoID: String) async throws -> VideoRating
    func rate(videoID: String, rating: VideoRating) async throws
    func addToPlaylist(videoID: String, playlistID: String) async throws
    /// Video id → length in seconds, for the ids YouTube knows.
    func durations(videoIDs: [String]) async throws -> [String: Int]
}

public protocol SponsorBlockProviding: Sendable {
    func segments(videoID: String) async throws -> [SponsorSegment]
}

public protocol DeArrowProviding: Sendable {
    /// A community title for the video, or nil when there is none (errors are swallowed).
    func betterTitle(videoID: String) async -> String?
}

public protocol SubscriptionFeedProviding: Sendable {
    /// The last feed that was written to disk, for an instant first paint.
    func cachedFeed() async -> [VideoSummary]
    func feed(channels: [SubscribedChannel], forceRefresh: Bool) async throws -> [VideoSummary]
}

public protocol HomeFeedProviding: Sendable {
    func homeFeed(history: [HistoryEntry], subscriptionVideos: [VideoSummary]) async -> HomeFeed
}

public protocol VisitorDataStoring: Sendable {
    func load() -> (value: String, fetchedAt: Date)?
    func save(value: String, fetchedAt: Date)
}
