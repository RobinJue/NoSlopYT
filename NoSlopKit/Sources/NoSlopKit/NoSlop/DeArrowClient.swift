import Foundation

/// DeArrow community titles through the 4-hex-character hash-prefix endpoint.
///
/// `GET {base}/api/branding/{sha256Prefix}` returns an object keyed by video id for every video whose id hashes to
/// that prefix; the server never learns which video is being shown. A video's replacement title is the first entry
/// of its `titles` list that
/// - is not the original title,
/// - is locked, or has at least 0 votes,
/// - and is not empty once a leading `>` (DeArrow's "do not auto-format" marker) and the whitespace around it are removed.
///
/// The whole prefix response is cached for an hour (reduced to the titles that passed), so the other videos of the
/// same response cost nothing.
///
/// `lookup` tells a video that has no better title (the server has no entry for the prefix, or none for the video, or
/// none that passes the rules above) from a lookup that did not work (no connection, a timeout, HTTP 429 or 5xx or any
/// other status, a body that is not a JSON object). The first is an answer, and is cached with the rest of the response;
/// the second is never cached, so the next lookup asks again. `betterTitle` is `lookup` as an optional string: the
/// original shows for both.
public actor DeArrowClient: DeArrowProviding {
    static let defaultBaseURL = URL(string: "https://sponsor.ajay.app")!
    private static let cacheTTL: TimeInterval = 3_600
    /// A title is a nicety; do not wait a minute for it.
    private static let requestTimeout: TimeInterval = 15

    private let http: any HTTPClient
    private let baseURL: URL
    /// Hash prefix -> (video id -> better title), for the videos of that response that have one.
    private let cache: TTLCache<String, [String: String]>
    private var inFlight: [String: Task<Fetched, Never>] = [:]

    public init(http: any HTTPClient, baseURL: URL = URL(string: "https://sponsor.ajay.app")!) {
        self.init(http: http, baseURL: baseURL, cacheTTL: Self.cacheTTL, now: { Date() })
    }

    /// Tests choose the cache lifetime and the clock.
    init(
        http: any HTTPClient,
        baseURL: URL = DeArrowClient.defaultBaseURL,
        cacheTTL: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.http = http
        self.baseURL = baseURL
        self.cache = TTLCache(ttl: cacheTTL, maxEntries: 100, now: now)
    }

    public func betterTitle(videoID: String) async -> String? {
        if case .title(let title) = await lookup(videoID: videoID) { return title }
        return nil
    }

    public func lookup(videoID: String) async -> DeArrowLookup {
        let prefix = HashPrefix.sha256Prefix(videoID)
        if let titles = await cache.value(for: prefix) { return Self.answer(for: videoID, in: .titles(titles)) }
        // Lookups that overlap and share a prefix share one request, and the failure of it.
        if let pending = inFlight[prefix] { return Self.answer(for: videoID, in: await pending.value) }

        let http = http
        let request = Self.makeRequest(prefix: prefix, baseURL: baseURL)
        let task = Task { await Self.fetch(request, with: http) }
        inFlight[prefix] = task
        defer { inFlight[prefix] = nil }

        let fetched = await task.value
        // Only an answer is cached; a lookup that failed is tried again next time.
        if case .titles(let titles) = fetched {
            await cache.insert(titles, for: prefix)
        }
        return Self.answer(for: videoID, in: fetched)
    }

    private static func answer(for videoID: String, in fetched: Fetched) -> DeArrowLookup {
        switch fetched {
        case .titles(let titles):
            guard let title = titles[videoID] else { return DeArrowLookup.none }
            return .title(title)
        case .failed:
            return .failed
        }
    }

    // MARK: Request

    private static func makeRequest(prefix: String, baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/branding/\(prefix)"))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// What a request for a prefix came to.
    private enum Fetched: Sendable {
        /// The usable titles of the response (video id -> title); empty when the server knows nothing for the prefix.
        case titles([String: String])
        /// No connection, a timeout, a status that says nothing about the titles, or a body that cannot be read.
        case failed
    }

    private static func fetch(_ request: URLRequest, with http: any HTTPClient) async -> Fetched {
        guard let (data, response) = try? await http.send(request) else { return .failed }
        switch response.statusCode {
        case 404:
            // Nothing is known for this prefix, which is an answer too.
            return .titles([:])
        case 200..<300:
            return parse(data).map(Fetched.titles) ?? .failed
        default:
            // 429 and 5xx: the server is busy or down. Anything else it says says nothing about these videos either.
            return .failed
        }
    }

    // MARK: Response

    /// Video id -> better title for the videos in a prefix response that have one; nil when it is not a JSON object.
    static func parse(_ data: Data) -> [String: String]? {
        guard let object = (try? JSON(data: data))?.object else { return nil }
        var titles: [String: String] = [:]
        for (videoID, entry) in object {
            if let title = bestTitle(in: entry["titles"]?.array ?? []) {
                titles[videoID] = title
            }
        }
        return titles
    }

    private static func bestTitle(in candidates: [JSON]) -> String? {
        for candidate in candidates {
            guard let raw = candidate["title"]?.string else { continue }
            if flag(candidate["original"]) == true { continue }
            let locked = flag(candidate["locked"]) ?? false
            // Without a vote count nothing vouches for an unlocked title.
            guard locked || (candidate["votes"]?.double ?? -1) >= 0 else { continue }
            let title = cleaned(raw)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// Without surrounding whitespace and without the leading `>` marker.
    private static func cleaned(_ title: String) -> String {
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix(">") { title.removeFirst() }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A JSON boolean, or a number used as one (0 and 1, as SponsorBlock's API does).
    private static func flag(_ json: JSON?) -> Bool? {
        switch json {
        case .bool(let value)?: return value
        case .number(let value)?: return value != 0
        default: return nil
        }
    }
}
