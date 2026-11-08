import Foundation

/// The constants of the TV sign-in (the probe copied them from MIT and Unlicense sources).
public enum TVAuth {
    public static let deviceCodeURL = "https://www.youtube.com/o/oauth2/device/code"   // JSON body
    public static let tokenURL = "https://www.youtube.com/o/oauth2/token"              // JSON body
    public static let deviceGrant = "http://oauth.net/grant_type/device/1.0"
    public static let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
    public static let deviceModel = "ytlr::"
    public static let revokeURLs = ["https://oauth2.googleapis.com/revoke", "https://www.youtube.com/o/oauth2/revoke"]
    /// The TV page whose script holds the client values: `<script id="base-js">`, first match of the YouTube.js pattern.
    public static let tvPage = "https://www.youtube.com/tv"

    static let clientPattern = #"clientId:"([^"]+)",[^"]*?:"([^"]+)""#
    static let minimumWait = 5
    static let slowDownExtra = 5
    static let refreshMargin: TimeInterval = 300
    static let deviceIDKey = "noslop.tvDeviceID"
}

/// YouTube's TV code sign-in: asks for a code, polls until it is approved, keeps the tokens in their own Keychain item and
/// refreshes them. Ported from the probe (`scripts/tv-probe/tvprobe/oauth.py`). Its errors are short plain sentences; no token,
/// code or client value is logged or put in an error.
public actor TVAuthService: RecommendationsAuthProviding {
    private struct ClientPair {
        let id: String
        let secret: String
    }

    private struct PendingSignIn {
        let deviceCode: String
        let userCode: String
        let expiresAt: Date
        let interval: Int
        let client: ClientPair
    }

    private let http: any HTTPClient
    private let store: any TVTokenStoring
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private var clientPair: ClientPair?
    private var pending: PendingSignIn?
    private var refreshTask: Task<TVCredentials, any Error>?
    private lazy var tvClient = TVClient(http: http, tokens: self)

    public init(
        http: any HTTPClient,
        store: any TVTokenStoring,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.http = http
        self.store = store
        self.defaults = defaults
        self.now = now
        self.sleep = sleep
    }

    // MARK: Sign-in

    public func currentAccount() async -> TVAccount? {
        guard let credentials = try? store.load() else { return nil }
        return TVAccount(name: credentials.accountName, connectedAt: credentials.connectedAt)
    }

    public func secondsLeft() async -> Int? {
        guard let credentials = try? store.load() else { return nil }
        return max(0, Int(credentials.expiresAt.timeIntervalSince(now()).rounded(.down)))
    }

    public func beginSignIn() async throws -> TVSignInPrompt {
        let client = try await clientValues()
        let body: JSON = [
            "client_id": .string(client.id),
            "scope": .string(TVAuth.scope),
            "device_id": .string(deviceID()),
            "device_model": .string(TVAuth.deviceModel),
        ]
        let (data, status) = try await send("POST", TVAuth.deviceCodeURL, headers: Self.jsonHeaders, body: try body.data())
        let reply = Self.object(data)
        guard status == 200,
              let deviceCode = reply["device_code"]?.string, !deviceCode.isEmpty,
              let userCode = reply["user_code"]?.string, !userCode.isEmpty,
              let page = reply["verification_url"]?.string,
              var components = URLComponents(string: page), components.scheme == "https",
              let expiresIn = reply["expires_in"]?.double
        else { throw Self.couldNotStart }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "user_code" } + [URLQueryItem(name: "user_code", value: userCode)]
        guard let url = components.url else { throw Self.couldNotStart }

        let expiresAt = now().addingTimeInterval(expiresIn)
        let interval = reply["interval"]?.int ?? TVAuth.minimumWait
        pending = PendingSignIn(deviceCode: deviceCode, userCode: userCode, expiresAt: expiresAt, interval: interval, client: client)
        return TVSignInPrompt(userCode: userCode, verificationURL: url, expiresAt: expiresAt)
    }

    public func completeSignIn(_ prompt: TVSignInPrompt) async throws -> TVAccount {
        guard let sign = pending, sign.userCode == prompt.userCode else { throw Self.expired }
        let request: Data = try ([
            "client_id": .string(sign.client.id),
            "client_secret": .string(sign.client.secret),
            "code": .string(sign.deviceCode),
            "grant_type": .string(TVAuth.deviceGrant),
        ] as JSON).data()

        var slowDowns = 0
        while true {
            try Self.checkCancelled()
            if now() >= sign.expiresAt {
                pending = nil
                throw Self.expired
            }
            let answer: Data?
            do {
                answer = try await send("POST", TVAuth.tokenURL, headers: Self.jsonHeaders, body: request).0
            } catch let error as NoSlopError {
                // A dropped connection while waiting is not the end of the sign-in; the expiry time bounds the wait.
                guard case .network = error else { pending = nil; throw error }
                answer = nil
            }
            if let answer {
                let reply = Self.object(answer)
                let error = reply["error"]?.string
                if error == nil, reply["access_token"]?.string != nil {
                    pending = nil
                    return try await finishSignIn(reply, client: sign.client)
                }
                switch error {
                case "authorization_pending": break
                case "slow_down": slowDowns += 1
                case "access_denied":
                    pending = nil
                    throw NoSlopError.oauth("The sign-in was declined.")
                case "expired_token":
                    pending = nil
                    throw Self.expired
                default:
                    pending = nil
                    throw Self.didNotWork
                }
            }
            do {
                try await sleep(.seconds(max(TVAuth.minimumWait, sign.interval) + TVAuth.slowDownExtra * slowDowns))
            } catch is CancellationError {
                throw NoSlopError.cancelled
            }
        }
    }

    private func finishSignIn(_ reply: [String: JSON], client: ClientPair) async throws -> TVAccount {
        let credentials = try Self.credentials(from: reply, keepingRefreshToken: nil, scope: TVAuth.scope, now: now(), client: client)
        var saved = credentials
        saved.connectedAt = now()
        do {
            try store.save(saved)
        } catch {
            throw NoSlopError.oauth("The sign-in couldn't be saved on this device.")
        }
        // Best effort: the name is a nicety, so any failure leaves the connection as it is.
        if let name = await fetchAccountName() {
            if var latest = try? store.load() {
                latest.accountName = name
                try? store.save(latest)
            }
        }
        guard let final = try? store.load() else { throw NoSlopError.recommendationsNotConnected }
        return TVAccount(name: final.accountName, connectedAt: final.connectedAt)
    }

    private func fetchAccountName() async -> String? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.region?.identifier ?? "US"
        let body: JSON = ["context": TVClientConfig.context(.tv, visitorData: nil, language: language, region: region)]
        guard let reply = try? await tvClient.post("account/accounts_list", body: body) else { return nil }
        let items = reply.findAll("accountItem")
        let item = items.first(where: { $0["isSelected"]?.bool == true }) ?? items.first
        let name = item?["accountName"]?["simpleText"]?.string ?? item?["accountName"]?["runs"]?[0]?["text"]?.string
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    // MARK: Tokens

    public func accessToken() async throws -> String {
        guard let credentials = try store.load() else { throw NoSlopError.recommendationsNotConnected }
        if credentials.expiresAt.timeIntervalSince(now()) < TVAuth.refreshMargin {
            return try await sharedRefresh().accessToken
        }
        return credentials.accessToken
    }

    public func refreshAfterUnauthorized() async throws -> String {
        try await sharedRefresh().accessToken
    }

    /// One refresh at a time: callers that arrive while one runs wait for its result.
    private func sharedRefresh() async throws -> TVCredentials {
        if let task = refreshTask { return try await task.value }
        let task = Task { try await self.performRefresh() }
        refreshTask = task
        return try await task.value
    }

    private func performRefresh() async throws -> TVCredentials {
        defer { refreshTask = nil }
        guard let stored = try store.load() else { throw NoSlopError.recommendationsNotConnected }
        let body: JSON = [
            "client_id": .string(stored.clientID),
            "client_secret": .string(stored.clientSecret),
            "refresh_token": .string(stored.refreshToken),
            "grant_type": "refresh_token",
        ]
        // A transport error (offline, cancelled) propagates and leaves the store alone.
        let (data, status) = try await send("POST", TVAuth.tokenURL, headers: Self.jsonHeaders, body: try body.data())
        let reply = Self.object(data)
        if let error = reply["error"]?.string {
            if ["invalid_grant", "invalid_client", "unauthorized_client"].contains(error) {
                try? store.clear()
                pending = nil
                throw NoSlopError.recommendationsNotConnected
            }
            throw NoSlopError.oauth("The connection couldn't be renewed. Try again later.")
        }
        guard status == 200 else { throw NoSlopError.http(status: status) }
        var renewed = try Self.credentials(
            from: reply, keepingRefreshToken: stored.refreshToken, scope: stored.scope, now: now(),
            client: ClientPair(id: stored.clientID, secret: stored.clientSecret)
        )
        renewed.accountName = stored.accountName
        renewed.connectedAt = stored.connectedAt
        // Disconnect (or an ended grant) may have run while the reply was on its way; never bring the credentials back.
        guard let current = try store.load(), current.refreshToken == stored.refreshToken else {
            throw NoSlopError.recommendationsNotConnected
        }
        do {
            try store.save(renewed)
        } catch {
            throw NoSlopError.oauth("The sign-in couldn't be saved on this device.")
        }
        return renewed
    }

    // MARK: Disconnect

    public func disconnect() async -> Bool {
        pending = nil
        refreshTask?.cancel()
        refreshTask = nil
        var revoked = false
        if let refreshToken = (try? store.load())?.refreshToken {
            let form = "token=" + Self.formEncode(refreshToken)
            let attempts: [(String, [String: String], Data?)] = [
                (TVAuth.revokeURLs[0], ["Content-Type": "application/x-www-form-urlencoded"], Data(form.utf8)),
                (TVAuth.revokeURLs[1], Self.jsonHeaders, try? ([ "token": .string(refreshToken) ] as JSON).data()),
            ]
            for (url, headers, body) in attempts {
                if let result = try? await send("POST", url, headers: headers, body: body), result.1 == 200 {
                    revoked = true
                    break
                }
            }
        }
        try? store.clear()
        return revoked
    }

    // MARK: Client values

    private func clientValues() async throws -> ClientPair {
        if let clientPair { return clientPair }
        let (page, pageStatus) = try await send("GET", TVAuth.tvPage, headers: ["User-Agent": TVClientConfig.tvUserAgent])
        guard pageStatus == 200,
              let html = String(data: page, encoding: .utf8),
              let scriptURL = Self.baseScriptURL(in: html)
        else { throw Self.couldNotStart }
        let (script, scriptStatus) = try await send("GET", scriptURL.absoluteString, headers: ["User-Agent": TVClientConfig.tvUserAgent])
        guard scriptStatus == 200,
              let text = String(data: script, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: TVAuth.clientPattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let idRange = Range(match.range(at: 1), in: text),
              let secretRange = Range(match.range(at: 2), in: text)
        else { throw Self.couldNotStart }
        let pair = ClientPair(id: String(text[idRange]), secret: String(text[secretRange]))
        clientPair = pair
        return pair
    }

    /// The `src` of the `<script id="base-js">` tag, made absolute against the TV page.
    static func baseScriptURL(in html: String) -> URL? {
        guard let tags = try? NSRegularExpression(pattern: #"<script\b[^>]*>"#),
              let source = try? NSRegularExpression(pattern: #"\bsrc="([^"]+)""#),
              let identity = try? NSRegularExpression(pattern: #"\bid="base-js""#)
        else { return nil }
        let whole = NSRange(html.startIndex..., in: html)
        for tag in tags.matches(in: html, range: whole) {
            guard let tagRange = Range(tag.range, in: html) else { continue }
            let text = String(html[tagRange])
            let inTag = NSRange(text.startIndex..., in: text)
            guard identity.firstMatch(in: text, range: inTag) != nil,
                  let found = source.firstMatch(in: text, range: inTag),
                  let srcRange = Range(found.range(at: 1), in: text) else { continue }
            return URL(string: String(text[srcRange]), relativeTo: URL(string: "https://www.youtube.com/"))?.absoluteURL
        }
        return nil
    }

    private func deviceID() -> String {
        if let existing = defaults.string(forKey: TVAuth.deviceIDKey), !existing.isEmpty { return existing }
        let created = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(created, forKey: TVAuth.deviceIDKey)
        return created
    }

    // MARK: Helpers

    private static let jsonHeaders = ["Content-Type": "application/json"]
    private static let couldNotStart = NoSlopError.oauth("The sign-in couldn't start. Try again later.")
    private static let expired = NoSlopError.oauth("The code expired. Start again.")
    private static let didNotWork = NoSlopError.oauth("The sign-in didn't work. Try again.")

    private static func checkCancelled() throws {
        if Task.isCancelled { throw NoSlopError.cancelled }
    }

    private static func object(_ data: Data) -> [String: JSON] {
        (try? JSON(data: data))?.object ?? [:]
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func credentials(
        from reply: [String: JSON], keepingRefreshToken old: String?, scope fallbackScope: String, now: Date, client: ClientPair
    ) throws -> TVCredentials {
        guard let access = reply["access_token"]?.string, !access.isEmpty else { throw didNotWork }
        let newRefresh = reply["refresh_token"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        guard let refresh = newRefresh ?? old else { throw didNotWork }
        let lifetime = reply["expires_in"]?.double ?? 0
        return TVCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(lifetime),
            scope: reply["scope"]?.string ?? fallbackScope,
            clientID: client.id,
            clientSecret: client.secret,
            accountName: nil,
            connectedAt: now
        )
    }

    /// One request to a fixed TV-interface address: https, an allowed host, no cookies, no token.
    private func send(_ method: String, _ urlString: String, headers: [String: String], body: Data? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: urlString), url.scheme == "https",
              let host = url.host, TVClientConfig.allowedHosts.contains(host) else {
            throw NoSlopError.network("That address is not allowed.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(TVClientConfig.tvUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await http.send(request)
        return (data, response.statusCode)
    }
}
