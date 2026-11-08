import Foundation

/// Hands out the access token of the TV connection. The auth service conforms; `TVClient` asks it for every request.
public protocol TVTokenProviding: Sendable {
    func accessToken() async throws -> String
    /// A new token after the server said 401. Throws `NoSlopError.recommendationsNotConnected` when the grant has ended.
    func refreshAfterUnauthorized() async throws -> String
}

/// The only place an Authorization header is set. It talks to YouTube as the TV app, through its own cookie-free session,
/// and only to the hosts in `TVClientConfig.allowedHosts` over plain https.
public actor TVClient {
    private static let requestTimeout: TimeInterval = 30

    private let http: any HTTPClient
    private let tokens: any TVTokenProviding

    public init(http: any HTTPClient, tokens: any TVTokenProviding) {
        self.http = http
        self.tokens = tokens
    }

    /// POSTs `body` to `https://<host>/youtubei/v1/<endpoint>?prettyPrint=false` as the TV app, signed in.
    /// - Returns: the parsed answer, or nil for an empty body or a 204.
    /// - Throws: `.recommendationsNotConnected` after a second 401, `.http(status:)` for any other non-2xx answer,
    ///   and `.network` or `.cancelled` from the transport. Nothing is sent when `host` is not on the allow-list.
    public func post(
        _ endpoint: String,
        body: JSON,
        profile: TVProfile = .tv,
        host: String = "www.youtube.com",
        visitorData: String? = nil
    ) async throws -> JSON? {
        guard TVClientConfig.allowedHosts.contains(host),
              let url = URL(string: "https://\(host)/youtubei/v1/\(endpoint)?prettyPrint=false") else {
            throw NoSlopError.network("That address is not allowed.")
        }
        let payload = try body.data()

        var token = try await tokens.accessToken()
        var (data, status) = try await send(url: url, payload: payload, profile: profile, token: token, visitorData: visitorData)
        if status == 401 {
            token = try await tokens.refreshAfterUnauthorized()
            (data, status) = try await send(url: url, payload: payload, profile: profile, token: token, visitorData: visitorData)
            if status == 401 { throw NoSlopError.recommendationsNotConnected }
        }
        guard (200..<300).contains(status) else { throw NoSlopError.http(status: status) }
        if status == 204 || data.isEmpty { return nil }
        return try JSON(data: data)
    }

    /// GETs `url` (a ping) as the TV app and returns the status only. The token goes along only when `authorized`.
    public func get(_ url: URL, profile: TVProfile, authorized: Bool) async throws -> Int {
        try Self.check(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(TVClientConfig.referer, forHTTPHeaderField: "Referer")
        if authorized {
            let token = try await tokens.accessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await http.send(request)
        try Self.check(response.url)
        return response.statusCode
    }

    private func send(url: URL, payload: Data, profile: TVProfile, token: String, visitorData: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(TVClientConfig.referer, forHTTPHeaderField: "Referer")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let visitorData, !visitorData.isEmpty {
            request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        let (data, response) = try await http.send(request)
        // A redirect off the allow-list means the answer is not YouTube's: drop it.
        try Self.check(response.url)
        return (data, response.statusCode)
    }

    /// Plain https, no credentials in the URL, the default port, an allowed host. A missing URL (no response URL) passes.
    private static func check(_ url: URL?) throws {
        guard let url else { return }
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host, TVClientConfig.allowedHosts.contains(host) else {
            throw NoSlopError.network("That address is not allowed.")
        }
    }
}
