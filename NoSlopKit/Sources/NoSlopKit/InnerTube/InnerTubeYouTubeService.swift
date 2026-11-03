import Foundation

/// `YouTubeService` backed by InnerTube.
///
/// Everything except `player` goes through the WEB client profile; this type only builds the requests and hands the
/// answers to the parsers of Tasks 3 and 4. A page the parsers cannot make anything of is an empty page; only the
/// two that cannot be empty (a video's details, a channel or playlist header) turn into `NoSlopError.decoding`.
public struct InnerTubeYouTubeService: YouTubeService {
    private let client: InnerTubeClient
    private let http: any HTTPClient
    private let parsers: YouTubeParsers
    private let detailsCache: TTLCache<String, VideoDetails>

    /// How long a watch page is reused (leaving a video and coming back should not cost a request).
    static let detailsLifetime: TimeInterval = 10 * 60

    public init(client: InnerTubeClient, http: any HTTPClient) {
        self.init(client: client, http: http, parsers: .live, now: { Date() })
    }

    /// Tests inject fake parsers (to test the facade without the real ones) and a clock for the cache.
    init(client: InnerTubeClient, http: any HTTPClient, parsers: YouTubeParsers, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.http = http
        self.parsers = parsers
        self.detailsCache = TTLCache(ttl: Self.detailsLifetime, maxEntries: 50, now: now)
    }

    // MARK: Search

    public func search(query: String, filter: SearchFilter) async throws -> Page<SearchItem> {
        var body: [String: JSON] = ["query": .string(query)]
        if let params = SearchParams.encode(filter) {
            body["params"] = .string(params)
        }
        return parsers.search(try await client.post(endpoint: "search", profile: .web, body: body))
    }

    public func searchMore(continuation: String) async throws -> Page<SearchItem> {
        parsers.search(try await client.post(endpoint: "search", profile: .web, body: ["continuation": .string(continuation)]))
    }

    public func suggestions(for query: String) async throws -> [String] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let config = client.config
        let address = "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt"
            + "&hl=\(YouTubeQueryEncoding.encode(config.hl))&gl=\(YouTubeQueryEncoding.encode(config.gl))&q=\(YouTubeQueryEncoding.encode(query))"
        guard let url = URL(string: address) else {
            throw NoSlopError.decoding("Could not build the suggestions request.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(ClientProfile.web.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw NoSlopError.http(status: response.statusCode)
        }
        return SuggestionsParser.parse(data)
    }

    // MARK: Watch page

    public func videoDetails(id: String) async throws -> VideoDetails {
        if let cached = await detailsCache.value(for: id) {
            return cached
        }
        let json = try await client.post(endpoint: "next", profile: .web, body: ["videoId": .string(id)])
        guard var details = parsers.watch(json, id) else {
            throw NoSlopError.decoding("The watch page for \(id) had an unexpected format.")
        }
        let related = parsers.related(json)
        details.related = related.items
        details.relatedContinuation = related.continuation
        await detailsCache.insert(details, for: id)
        return details
    }

    public func moreRelated(continuation: String) async throws -> Page<VideoSummary> {
        parsers.relatedContinuation(try await client.post(endpoint: "next", profile: .web, body: ["continuation": .string(continuation)]))
    }

    public func comments(continuation: String) async throws -> CommentsPage {
        parsers.comments(try await client.post(endpoint: "next", profile: .web, body: ["continuation": .string(continuation)]))
    }

    // MARK: Channels

    public func channel(id: String) async throws -> ChannelPage {
        let json = try await client.post(endpoint: "browse", profile: .web, body: browseBody(id: id, tab: .videos))
        guard let page = parsers.channelPage(json) else {
            throw NoSlopError.decoding("The channel page for \(id) had an unexpected format.")
        }
        return page
    }

    public func channelTab(channelID: String, tab: ChannelTabKind) async throws -> Page<SearchItem> {
        parsers.channelTab(try await client.post(endpoint: "browse", profile: .web, body: browseBody(id: channelID, tab: tab)))
    }

    public func channelMore(continuation: String) async throws -> Page<SearchItem> {
        parsers.channelContinuation(try await client.post(endpoint: "browse", profile: .web, body: ["continuation": .string(continuation)]))
    }

    private func browseBody(id: String, tab: ChannelTabKind) -> [String: JSON] {
        var body: [String: JSON] = ["browseId": .string(id)]
        if let params = ChannelParser.tabParams[tab] {
            body["params"] = .string(params)
        }
        return body
    }

    // MARK: Playlists

    public func playlist(id: String) async throws -> PlaylistPage {
        let json = try await client.post(endpoint: "browse", profile: .web, body: ["browseId": .string("VL" + id)])
        guard let page = parsers.playlist(json, id) else {
            throw NoSlopError.decoding("The playlist \(id) had an unexpected format.")
        }
        return page
    }

    public func playlistMore(continuation: String) async throws -> Page<VideoSummary> {
        parsers.playlistContinuation(try await client.post(endpoint: "browse", profile: .web, body: ["continuation": .string(continuation)]))
    }

    // MARK: Links

    /// Links that identify themselves are resolved without the network. Anything else on a YouTube host (a handle,
    /// a custom channel URL) is looked up with `navigation/resolve_url`; links on other hosts are never sent to
    /// YouTube. A link YouTube does not know (HTTP 404) resolves to nil.
    public func resolve(url: URL) async throws -> ResolvedURL? {
        if let local = YouTubeURL.resolveLocally(url) {
            return local
        }
        guard YouTubeURL.isYouTubeWebURL(url) else { return nil }
        do {
            let json = try await client.post(endpoint: "navigation/resolve_url", profile: .web, body: ["url": .string(url.absoluteString)])
            return ResolveURLParser.parse(json)
        } catch NoSlopError.http(status: 404) {
            return nil
        }
    }
}

/// The parsers behind the facade, as functions, so tests can substitute them.
struct YouTubeParsers: Sendable {
    var search: @Sendable (JSON) -> Page<SearchItem>
    var watch: @Sendable (JSON, String) -> VideoDetails?
    var related: @Sendable (JSON) -> Page<VideoSummary>
    var relatedContinuation: @Sendable (JSON) -> Page<VideoSummary>
    var comments: @Sendable (JSON) -> CommentsPage
    var channelPage: @Sendable (JSON) -> ChannelPage?
    var channelTab: @Sendable (JSON) -> Page<SearchItem>
    var channelContinuation: @Sendable (JSON) -> Page<SearchItem>
    var playlist: @Sendable (JSON, String) -> PlaylistPage?
    var playlistContinuation: @Sendable (JSON) -> Page<VideoSummary>

    static let live = YouTubeParsers(
        search: { SearchParser.parse($0) },
        watch: { WatchMetadataParser.parse($0, videoID: $1) },
        related: { RelatedParser.parse(next: $0) },
        relatedContinuation: { RelatedParser.parseContinuation($0) },
        comments: { CommentsParser.parse($0) },
        channelPage: { ChannelParser.parseChannelPage($0) },
        channelTab: { ChannelParser.parseTab($0) },
        channelContinuation: { ChannelParser.parseContinuation($0) },
        playlist: { PlaylistParser.parse($0, playlistID: $1) },
        playlistContinuation: { PlaylistParser.parseContinuation($0) }
    )
}
