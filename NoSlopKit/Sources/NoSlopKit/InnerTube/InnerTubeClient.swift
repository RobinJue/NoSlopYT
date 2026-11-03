import Foundation

/// The InnerTube transport: obtains and caches `visitorData`, builds the request context for a client profile,
/// POSTs JSON and returns the parsed response.
///
/// Every request carries the visitor token twice (`context.client.visitorData` and `X-Goog-Visitor-Id`), plus
/// `hl`/`gl` from the configuration and `Origin: https://www.youtube.com`. The token is cached for seven days in
/// memory and in the `VisitorDataStoring`; callers that were told it was rejected (a bot check on `player`) ask
/// for a fresh one with `visitorData(forceRefresh: true)`.
public actor InnerTubeClient {
    /// Immutable, so it is `nonisolated`: readable from any module without `await`.
    public nonisolated let config: InnerTubeConfig

    /// How long a `visitorData` token is reused before a new one is fetched.
    static let visitorDataLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// A token fetched "in the future" (the clock was set back) is not trusted beyond this much skew.
    private static let clockSkewTolerance: TimeInterval = 60

    private static let origin = "https://www.youtube.com"
    private static let requestTimeout: TimeInterval = 30

    private let http: any HTTPClient
    private let visitorStore: any VisitorDataStoring
    private let now: @Sendable () -> Date

    private var cachedVisitorData: (value: String, fetchedAt: Date)?
    /// The fetch in progress, so concurrent callers share one request instead of each making their own.
    private var visitorFetch: Task<String, any Error>?

    public init(
        http: any HTTPClient,
        config: InnerTubeConfig,
        visitorStore: any VisitorDataStoring = UserDefaultsVisitorDataStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.config = config
        self.visitorStore = visitorStore
        self.now = now
    }

    // MARK: visitorData

    /// The visitor token to send with requests: the cached one while it is younger than seven days, else a new one
    /// (from `sw.js_data`, falling back to `youtubei/v1/visitor_id`). `forceRefresh` skips the cache.
    public func visitorData(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let current = freshVisitorData() {
            return current
        }
        if let visitorFetch {
            return try await visitorFetch.value
        }
        let fetch = Task { try await self.fetchVisitorData() }
        visitorFetch = fetch
        defer { visitorFetch = nil }
        return try await fetch.value
    }

    private func freshVisitorData() -> String? {
        if let cached = cachedVisitorData, isFresh(cached.fetchedAt) {
            return cached.value
        }
        // Another client instance (or an earlier launch) may have stored a newer token.
        if let stored = visitorStore.load(), isFresh(stored.fetchedAt) {
            cachedVisitorData = stored
            return stored.value
        }
        return nil
    }

    private func isFresh(_ fetchedAt: Date) -> Bool {
        let age = now().timeIntervalSince(fetchedAt)
        return age >= -Self.clockSkewTolerance && age < Self.visitorDataLifetime
    }

    private func fetchVisitorData() async throws -> String {
        let value = try await requestVisitorData()
        let fetchedAt = now()
        cachedVisitorData = (value, fetchedAt)
        visitorStore.save(value: value, fetchedAt: fetchedAt)
        return value
    }

    private func requestVisitorData() async throws -> String {
        // 1. GET sw.js_data: three kilobytes, and the token is in it.
        if let token = try await tokenFromServiceWorkerData() {
            return token
        }
        // 2. POST visitor_id, which answers with the token in its responseContext. It cannot carry a token itself.
        let response = try await send(endpoint: "visitor_id", profile: .web, body: [:], visitorData: nil)
        guard let raw = response["responseContext"]?["visitorData"]?.string,
              let token = SwJsDataParser.normalizedToken(raw) else {
            throw NoSlopError.decoding("YouTube did not issue a visitor id.")
        }
        return token
    }

    /// nil when YouTube answered but not usably (so the fallback should run); transport failures are thrown.
    private func tokenFromServiceWorkerData() async throws -> String? {
        guard let url = URL(string: Self.origin + "/sw.js_data") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(ClientProfile.web.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await http.send(request)
            guard (200..<300).contains(response.statusCode) else { return nil }
            return SwJsDataParser.visitorData(from: String(decoding: data, as: UTF8.self))
        } catch NoSlopError.http {
            return nil
        }
    }

    // MARK: Requests

    /// POSTs `body` plus the client context to `youtubei/v1/<endpoint>` and returns the JSON answer.
    /// - Throws: `NoSlopError.http(status:)` for a non-2xx answer, `.decoding` when the answer is not JSON, and
    ///   whatever the `HTTPClient` throws (`.network`, `.cancelled`).
    public func post(endpoint: String, profile: ClientProfile, body: [String: JSON]) async throws -> JSON {
        let token = try await visitorData()
        return try await send(endpoint: endpoint, profile: profile, body: body, visitorData: token)
    }

    private func send(endpoint: String, profile: ClientProfile, body: [String: JSON], visitorData: String?) async throws -> JSON {
        guard let url = URL(string: Self.origin + "/youtubei/v1/\(endpoint)?prettyPrint=false") else {
            throw NoSlopError.decoding("Invalid InnerTube endpoint '\(endpoint)'.")
        }

        // The configured fields win over the profile's extras, and the context is always the transport's own.
        var client = profile.extraClientFields.mapValues { JSON.string($0) }
        client["clientName"] = .string(profile.clientName)
        client["clientVersion"] = .string(profile.clientVersion)
        client["hl"] = .string(config.hl)
        client["gl"] = .string(config.gl)
        if let visitorData {
            client["visitorData"] = .string(visitorData)
        }
        var payload = body
        payload["context"] = .object(["client": .object(client)])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSON.object(payload).data()
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(profile.clientNameID), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw NoSlopError.http(status: response.statusCode)
        }
        return try JSON(data: data)
    }
}

/// Percent-encoding for values placed in a query string by hand. `URLComponents` leaves "+", "&" and "=" alone in
/// query values, which changes what the server reads, so everything but the unreserved characters is escaped.
enum YouTubeQueryEncoding {
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
