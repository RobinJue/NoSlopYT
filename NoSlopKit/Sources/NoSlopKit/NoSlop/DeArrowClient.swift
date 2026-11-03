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
/// same response cost nothing. Every failure just means "no better title": the original is shown.
public actor DeArrowClient: DeArrowProviding {
    static let defaultBaseURL = URL(string: "https://sponsor.ajay.app")!
    private static let cacheTTL: TimeInterval = 3_600
    /// A title is a nicety; do not wait a minute for it.
    private static let requestTimeout: TimeInterval = 15

    private let http: any HTTPClient
    private let baseURL: URL
    /// Hash prefix -> (video id -> better title), for the videos of that response that have one.
    private let cache: TTLCache<String, [String: String]>
    private var inFlight: [String: Task<[String: String]?, Never>] = [:]

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
        let prefix = HashPrefix.sha256Prefix(videoID)
        if let titles = await cache.value(for: prefix) { return titles[videoID] }
        // Lookups that overlap and share a prefix share one request.
        if let pending = inFlight[prefix] { return await pending.value?[videoID] }

        let http = http
        let request = Self.makeRequest(prefix: prefix, baseURL: baseURL)
        let task = Task { await Self.fetch(request, with: http) }
        inFlight[prefix] = task
        defer { inFlight[prefix] = nil }

        guard let titles = await task.value else { return nil }
        await cache.insert(titles, for: prefix)
        return titles[videoID]
    }

    // MARK: Request

    private static func makeRequest(prefix: String, baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/branding/\(prefix)"))
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// The usable titles of a prefix response; nil when the lookup failed (and should be tried again next time).
    private static func fetch(_ request: URLRequest, with http: any HTTPClient) async -> [String: String]? {
        guard let (data, response) = try? await http.send(request) else { return nil }
        switch response.statusCode {
        case 404:
            // Nothing is known for this prefix, which is an answer too.
            return [:]
        case 200..<300:
            return parse(data)
        default:
            return nil
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
