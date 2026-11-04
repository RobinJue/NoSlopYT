import Foundation

/// SponsorBlock segment lookups through the 4-hex-character hash-prefix endpoint.
///
/// `GET {base}/api/skipSegments/{sha256Prefix}?categories=[...]&actionTypes=["skip","mute","poi"]` returns the
/// segments of every video whose id hashes to that prefix; only the requested video's entries are kept, so the
/// server never learns which video is being watched. Results are cached per video for an hour, including "no
/// segments" (HTTP 404). Failures are not cached.
public actor SponsorBlockClient: SponsorBlockProviding {
    static let defaultBaseURL = URL(string: "https://sponsor.ajay.app")!
    private static let cacheTTL: TimeInterval = 3_600
    /// A lookup is a nicety; do not make anything wait a minute for it.
    private static let requestTimeout: TimeInterval = 15

    private let http: any HTTPClient
    private let baseURL: URL
    private let cache: TTLCache<String, [SponsorSegment]>
    private var inFlight: [String: Task<[SponsorSegment], any Error>] = [:]

    public init(http: any HTTPClient, baseURL: URL = URL(string: "https://sponsor.ajay.app")!) {
        self.init(http: http, baseURL: baseURL, cacheTTL: Self.cacheTTL, now: { Date() })
    }

    /// Tests choose the cache lifetime and the clock.
    init(
        http: any HTTPClient,
        baseURL: URL = SponsorBlockClient.defaultBaseURL,
        cacheTTL: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.http = http
        self.baseURL = baseURL
        self.cache = TTLCache(ttl: cacheTTL, maxEntries: 200, now: now)
    }

    public func segments(videoID: String) async throws -> [SponsorSegment] {
        if let cached = await cache.value(for: videoID) { return cached }
        // Lookups for the same video that overlap share one request.
        if let pending = inFlight[videoID] { return try await pending.value }

        let http = http
        let request = Self.makeRequest(videoID: videoID, baseURL: baseURL)
        let task = Task { try await Self.fetch(request, videoID: videoID, with: http) }
        inFlight[videoID] = task
        defer { inFlight[videoID] = nil }

        let segments = try await task.value
        await cache.insert(segments, for: videoID)
        return segments
    }

    // MARK: Request

    private static let categoriesParameter: String = {
        "[" + SponsorCategory.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
    }()

    private static let actionTypesParameter = #"["skip","mute","poi"]"#

    private static func makeRequest(videoID: String, baseURL: URL) -> URLRequest {
        let endpoint = baseURL.appendingPathComponent("api/skipSegments/\(HashPrefix.sha256Prefix(videoID))")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "categories", value: categoriesParameter),
            URLQueryItem(name: "actionTypes", value: actionTypesParameter),
        ]
        var request = URLRequest(url: components?.url ?? endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func fetch(_ request: URLRequest, videoID: String, with http: any HTTPClient) async throws -> [SponsorSegment] {
        let (data, response) = try await http.send(request)
        switch response.statusCode {
        case 404, 204:
            return []
        case 200..<300:
            return try parse(data, videoID: videoID)
        default:
            throw NoSlopError.http(status: response.statusCode)
        }
    }

    // MARK: Response

    /// The segments of `videoID` in a prefix response (a list of `{videoID, segments}` for many videos), by start
    /// time. Entries that cannot be mapped (a category or action this app does not know, bad times) are skipped.
    static func parse(_ data: Data, videoID: String) throws -> [SponsorSegment] {
        let json = try JSON(data: data)
        guard let entries = json.array else {
            throw NoSlopError.decoding("SponsorBlock did not answer with a list.")
        }
        var segments: [SponsorSegment] = []
        for entry in entries where entry["videoID"]?.string == videoID {
            for raw in entry["segments"]?.array ?? [] {
                if let segment = segment(from: raw) { segments.append(segment) }
            }
        }
        segments.sort { ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id) }
        return segments
    }

    private static func segment(from raw: JSON) -> SponsorSegment? {
        guard let id = raw["UUID"]?.string, !id.isEmpty,
              let category = raw["category"]?.string.flatMap(SponsorCategory.init(rawValue:)),
              let actionType = raw["actionType"]?.string.flatMap(SegmentActionType.init(rawValue:)),
              let times = raw["segment"]?.array, times.count == 2,
              let start = times[0].double, let end = times[1].double,
              start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
        // A highlight is a single moment (start == end); anything else needs a length.
        guard end > start || actionType == .poi else { return nil }
        // The length of the video the segment was submitted for. The service sends 0 when it does not know; that and
        // anything unusable is "unknown".
        let submittedLength = raw["videoDuration"]?.double.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return SponsorSegment(
            id: id,
            category: category,
            actionType: actionType,
            start: start,
            end: end,
            videoDuration: submittedLength
        )
    }
}
