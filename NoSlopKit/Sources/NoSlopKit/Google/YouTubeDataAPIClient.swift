import Foundation

/// `YouTubeAccountService` over the official YouTube Data API v3, acting as the signed-in user.
///
/// Every request carries a bearer token from `auth`, asked for again on each request (the auth service owns expiry
/// and refresh). When the API answers 401, the token is refreshed once and the request is repeated once; a second 401
/// is reported as `.http(status: 401)`.
///
/// Errors: `reason` `quotaExceeded` or `dailyLimitExceeded` in the error body maps to `.quotaExceeded`; no
/// credentials map to `.notSignedIn`; anything else non-2xx maps to `.http(status:)`; transport errors pass through.
public struct YouTubeDataAPIClient: YouTubeAccountService {
    private static let baseURL = "https://www.googleapis.com/youtube/v3/"
    private static let pageSize = "50"
    /// `videos.list` takes at most 50 ids per request.
    private static let maxIDsPerRequest = 50
    /// A safety net against a server that never stops paginating: 200 pages of 50 are 10,000 items.
    private static let maxPages = 200

    private let http: any HTTPClient
    private let auth: any GoogleAuthProviding

    public init(http: any HTTPClient, auth: any GoogleAuthProviding) {
        self.http = http
        self.auth = auth
    }

    // MARK: Subscriptions

    /// All subscriptions of the account, alphabetically, following every page.
    public func subscriptions() async throws -> [SubscribedChannel] {
        try await allItems(
            path: "subscriptions",
            query: [("part", "snippet"), ("mine", "true"), ("maxResults", Self.pageSize), ("order", "alphabetical")],
            map: GoogleDataAPIMapper.subscription
        )
    }

    /// Subscribes and returns the subscription id. Subscribing to a channel that is already subscribed returns the
    /// existing subscription's id, so the call is idempotent.
    public func subscribe(channelID: String) async throws -> String {
        let payload: JSON = ["snippet": ["resourceId": ["kind": "youtube#channel", "channelId": .string(channelID)]]]
        let (data, status) = try await send(method: "POST", path: "subscriptions", query: [("part", "snippet")], body: try payload.data())
        if Self.isSuccess(status) {
            guard let id = try JSON(data: data)["id"]?.string, !id.isEmpty else {
                throw NoSlopError.decoding("YouTube did not return the new subscription.")
            }
            return id
        }
        if status == 400, Self.errorReasons(in: data).contains("subscriptionDuplicate"),
           let existing = try await existingSubscriptionID(channelID: channelID) {
            return existing
        }
        throw Self.error(status: status, data: data)
    }

    /// Unsubscribes. A subscription that no longer exists counts as done.
    public func unsubscribe(subscriptionID: String) async throws {
        let (data, status) = try await send(method: "DELETE", path: "subscriptions", query: [("id", subscriptionID)])
        if Self.isSuccess(status) { return }
        if status == 404, Self.errorReasons(in: data).contains("subscriptionNotFound") { return }
        throw Self.error(status: status, data: data)
    }

    private func existingSubscriptionID(channelID: String) async throws -> String? {
        let page = try await json(path: "subscriptions", query: [("part", "id"), ("mine", "true"), ("forChannelId", channelID)])
        return page["items"]?[0]?["id"]?.string
    }

    // MARK: Playlists

    /// The account's own playlists, following every page.
    public func myPlaylists() async throws -> [PlaylistSummary] {
        try await allItems(
            path: "playlists",
            query: [("part", "snippet,contentDetails"), ("mine", "true"), ("maxResults", Self.pageSize)],
            map: GoogleDataAPIMapper.playlist
        )
    }

    /// One page of a playlist's videos (private and deleted ones left out). `continuation` is the next page token.
    public func playlistItems(playlistID: String, pageToken: String?) async throws -> Page<VideoSummary> {
        let page = try await json(
            path: "playlistItems",
            query: [("part", "snippet,contentDetails"), ("playlistId", playlistID), ("maxResults", Self.pageSize)] + Self.pageTokenItem(pageToken)
        )
        return Page(items: (page["items"]?.array ?? []).compactMap(GoogleDataAPIMapper.playlistItemVideo), continuation: Self.nextPageToken(in: page))
    }

    public func addToPlaylist(videoID: String, playlistID: String) async throws {
        let payload: JSON = ["snippet": ["playlistId": .string(playlistID), "resourceId": ["kind": "youtube#video", "videoId": .string(videoID)]]]
        try await expectSuccess(method: "POST", path: "playlistItems", query: [("part", "snippet")], body: try payload.data())
    }

    // MARK: Videos and ratings

    /// One page of the videos the account liked. `continuation` is the next page token.
    public func likedVideos(pageToken: String?) async throws -> Page<VideoSummary> {
        let page = try await json(
            path: "videos",
            query: [("part", "snippet,contentDetails,statistics"), ("myRating", "like"), ("maxResults", Self.pageSize)] + Self.pageTokenItem(pageToken)
        )
        return Page(items: (page["items"]?.array ?? []).compactMap(GoogleDataAPIMapper.video), continuation: Self.nextPageToken(in: page))
    }

    public func rating(videoID: String) async throws -> VideoRating {
        let response = try await json(path: "videos/getRating", query: [("id", videoID)])
        // "like", "dislike", "none"; "unspecified" (never rated) and anything new count as none.
        return VideoRating(rawValue: response["items"]?[0]?["rating"]?.string ?? "") ?? VideoRating.none
    }

    public func rate(videoID: String, rating: VideoRating) async throws {
        try await expectSuccess(method: "POST", path: "videos/rate", query: [("id", videoID), ("rating", rating.rawValue)])
    }

    /// Video id -> length in seconds for the ids YouTube knows, 50 ids per request. Ids that are unknown, and live
    /// streams or premieres (no length yet), are left out. Duplicate ids are asked for once.
    ///
    /// `maxResults` is deliberately not sent: the API reference says it is not supported together with `id`.
    public func durations(videoIDs: [String]) async throws -> [String: Int] {
        var seen = Set<String>()
        let ids = videoIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        var result: [String: Int] = [:]
        for start in stride(from: 0, to: ids.count, by: Self.maxIDsPerRequest) {
            let batch = ids[start..<min(start + Self.maxIDsPerRequest, ids.count)]
            let page = try await json(path: "videos", query: [("part", "contentDetails"), ("id", batch.joined(separator: ","))])
            for item in page["items"]?.array ?? [] {
                if let id = item["id"]?.string, let seconds = GoogleDataAPIMapper.seconds(fromISO8601: item["contentDetails"]?["duration"]?.string) {
                    result[id] = seconds
                }
            }
        }
        return result
    }

    // MARK: Requests

    /// Follows `nextPageToken` until the last page (or a repeated token, or the page cap), mapping each item.
    private func allItems<T>(path: String, query: [(String, String)], map: (JSON) -> T?) async throws -> [T] {
        var results: [T] = []
        var seenTokens = Set<String>()
        var pageToken: String?
        for _ in 0..<Self.maxPages {
            let page = try await json(path: path, query: query + Self.pageTokenItem(pageToken))
            results += (page["items"]?.array ?? []).compactMap(map)
            guard let next = Self.nextPageToken(in: page), seenTokens.insert(next).inserted else { break }
            pageToken = next
        }
        return results
    }

    /// A 2xx JSON response, or the mapped error.
    private func json(method: String = "GET", path: String, query: [(String, String)], body: Data? = nil) async throws -> JSON {
        let (data, status) = try await send(method: method, path: path, query: query, body: body)
        guard Self.isSuccess(status) else { throw Self.error(status: status, data: data) }
        return try JSON(data: data)
    }

    /// For calls whose answer has no content we need (204 or an echo of the created resource).
    private func expectSuccess(method: String, path: String, query: [(String, String)], body: Data? = nil) async throws {
        let (data, status) = try await send(method: method, path: path, query: query, body: body)
        guard Self.isSuccess(status) else { throw Self.error(status: status, data: data) }
    }

    /// Sends one authorized request and returns whatever status came back. A 401 refreshes the token and repeats the
    /// request once.
    private func send(method: String, path: String, query: [(String, String)], body: Data? = nil) async throws -> (data: Data, status: Int) {
        let url = try Self.url(path: path, query: query)
        var token = try await auth.accessToken()
        var (data, response) = try await http.send(Self.request(url: url, method: method, body: body, token: token))
        if response.statusCode == 401 {
            token = try await replacement(for: token)
            (data, response) = try await http.send(Self.request(url: url, method: method, body: body, token: token))
        }
        return (data, response.statusCode)
    }

    /// A token to replace one the API rejected. The real auth service refreshes on demand; any other provider is
    /// simply asked again.
    private func replacement(for rejected: String) async throws -> String {
        if let refreshing = auth as? any GoogleTokenRefreshing {
            return try await refreshing.refreshedAccessToken(replacing: rejected)
        }
        return try await auth.accessToken()
    }

    private static func url(path: String, query: [(String, String)]) throws -> URL {
        let suffix = query.isEmpty ? "" : "?" + GoogleURLEncoding.queryString(query)
        guard let url = URL(string: baseURL + path + suffix) else { throw NoSlopError.decoding("The request could not be built.") }
        return url
    }

    private static func request(url: URL, method: String, body: Data?, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        } else if method == "POST" {
            request.httpBody = Data()  // the API wants a Content-Length even when there is nothing to send
        }
        return request
    }

    // MARK: Responses

    private static func isSuccess(_ status: Int) -> Bool {
        (200..<300).contains(status)
    }

    private static func pageTokenItem(_ token: String?) -> [(String, String)] {
        guard let token, !token.isEmpty else { return [] }
        return [("pageToken", token)]
    }

    private static func nextPageToken(in page: JSON) -> String? {
        guard let token = page["nextPageToken"]?.string, !token.isEmpty else { return nil }
        return token
    }

    /// The `reason` values of an API error body: `error.errors[].reason` (and `error.details[].reason`).
    private static func errorReasons(in data: Data) -> Set<String> {
        guard let json = try? JSON(data: data) else { return [] }
        let entries = (json["error"]?["errors"]?.array ?? []) + (json["error"]?["details"]?.array ?? [])
        return Set(entries.compactMap { $0["reason"]?.string })
    }

    private static func error(status: Int, data: Data) -> NoSlopError {
        let reasons = errorReasons(in: data)
        if reasons.contains("quotaExceeded") || reasons.contains("dailyLimitExceeded") {
            return .quotaExceeded
        }
        return .http(status: status)
    }
}
