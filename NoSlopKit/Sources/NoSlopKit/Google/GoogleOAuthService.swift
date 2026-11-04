import Foundation

/// Google sign-in: authorization-code flow with PKCE in a web session the app shows, token refresh, sign-out.
///
/// - There is no client secret: the OAuth client is a public iOS client and PKCE (S256) protects the code exchange.
/// - Credentials live in the injected `TokenStoring` (the Keychain in the app). The store is read on every call, so
///   it stays the single source of truth.
/// - Concurrent callers that find an expired token share one refresh request.
/// - A refresh answered with `invalid_grant` (the grant was revoked or expired) signs the user out: the credentials
///   are cleared and `.notSignedIn` is thrown. Any other failure leaves the credentials alone, so going offline
///   never signs anyone out.
/// - Nothing here logs or prints, and no token ends up in an error message.
public actor GoogleOAuthService: GoogleAuthProviding {
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"
    private static let userInfoEndpoint = URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!
    /// Signing out must not wait long for Google; the credentials are gone locally either way.
    private static let revokeTimeout: TimeInterval = 10
    private static let defaultTokenLifetime: TimeInterval = 3600
    /// Google's access tokens live an hour; anything beyond a month is a garbled number, not a lifetime.
    private static let maximumTokenLifetime: TimeInterval = 30 * 24 * 3600

    private let http: any HTTPClient
    private let store: any TokenStoring
    private let now: @Sendable () -> Date

    /// Bumped whenever the stored credentials are replaced or removed, so a refresh that was already in flight
    /// notices and throws its result away instead of writing it back.
    private var generation = 0
    private var refreshTask: Task<StoredCredentials?, any Error>?
    private var isSigningIn = false

    public init(http: any HTTPClient, store: any TokenStoring, now: @escaping @Sendable () -> Date = { Date() }) {
        self.http = http
        self.store = store
        self.now = now
    }

    // MARK: GoogleAuthProviding

    /// The signed-in account, read from the store without any network. An unreadable store counts as signed out.
    public func currentAccount() async -> GoogleAccount? {
        guard let credentials = try? store.load() else { return nil }
        return credentials.account
    }

    /// Runs the whole flow: web sign-in, code exchange, account lookup, storing the credentials.
    ///
    /// - Throws: `.googleNotConfigured` for a client ID that cannot work, `.cancelled` when the user backs out of
    ///   the web page, `.oauth` for anything Google or the redirect reports, and transport errors unchanged.
    ///   The previous session, if any, is only replaced when everything succeeded.
    public func signIn(clientID: String, authenticator: any WebAuthenticating) async throws -> GoogleAccount {
        guard let config = GoogleOAuthConfig(clientID: clientID) else { throw NoSlopError.googleNotConfigured }
        guard !isSigningIn else { throw NoSlopError.oauth("sign-in already in progress") }
        isSigningIn = true
        defer { isSigningIn = false }

        let verifier = PKCE.makeVerifier()
        let state = GoogleRandom.string(length: 32)
        let authorizationURL = config.authorizationURL(state: state, codeChallenge: PKCE.challenge(for: verifier))
        let callback = try await authenticator.authenticate(url: authorizationURL, callbackScheme: config.redirectScheme)
        let code = try Self.authorizationCode(in: callback, expectedState: state)

        let response: JSON
        do {
            response = try await requestTokens([
                ("grant_type", "authorization_code"),
                ("code", code),
                ("code_verifier", verifier),
                ("client_id", config.clientID),
                ("redirect_uri", config.redirectURI),
            ])
        } catch let failure as TokenEndpointFailure {
            throw failure.error
        }
        let tokens = try Self.tokens(from: response, at: now(), keeping: nil)
        // The consent screen lets the user untick individual permissions. Without the YouTube one every account feature
        // would fail later with a puzzling error, so the session is refused here and nothing of it is kept.
        guard Self.grantsYouTubeAccess(tokens.scope) else { throw Self.youTubeAccessNotGranted }
        let account = try await account(for: tokens)

        try store.save(StoredCredentials(clientID: config.clientID, tokens: tokens, account: account))
        supersedeRefreshInFlight()
        return account
    }

    /// Forgets the credentials at once, and asks Google to revoke the grant (best effort, short timeout).
    ///
    /// Returns as soon as the credentials are gone: what Google answers changes nothing here, so nobody waits for it.
    /// The request goes out from a task of its own, which `revokeTimeout` ends. (Waiting for it kept the app showing
    /// the account, with a busy Sign out button, for as long as a slow connection took to answer.)
    public func signOut() async {
        let previous = try? store.load()
        dropCredentials()
        guard let tokens = previous?.tokens else { return }
        // Revoking the refresh token ends the whole grant, access tokens included.
        let token = tokens.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? tokens.accessToken
        let http = http
        Task { await Self.revoke(token, using: http) }
    }

    /// A valid access token, refreshed first when it is expired or about to be.
    public func accessToken() async throws -> String {
        try await validCredentials(rejecting: nil).tokens.accessToken
    }

    /// A different access token than `rejected`, refreshing when the stored one is still that token. Used when the
    /// API answered 401 for a token the clock considered valid. If a concurrent caller already replaced it, this
    /// returns the replacement without another request.
    func refreshedAccessToken(replacing rejected: String) async throws -> String {
        try await validCredentials(rejecting: rejected).tokens.accessToken
    }

    // MARK: Credentials

    private func loadCredentials() throws -> StoredCredentials {
        guard let credentials = try store.load() else { throw NoSlopError.notSignedIn }
        return credentials
    }

    /// Credentials whose access token is usable now (not expired, and not `rejected`), refreshing when needed.
    private func validCredentials(rejecting rejected: String?) async throws -> StoredCredentials {
        // More than one pass only happens when the credentials were replaced while a refresh was in flight.
        for _ in 0..<3 {
            let credentials = try loadCredentials()
            if !credentials.tokens.isExpired(now: now()), credentials.tokens.accessToken != rejected {
                return credentials
            }
            if let refreshed = try await refresh(credentials) {
                return refreshed
            }
        }
        throw NoSlopError.notSignedIn
    }

    /// Joins the refresh that is already running, or starts one. Returns nil when the credentials were signed out or
    /// replaced meanwhile, so the caller should look at the store again.
    private func refresh(_ credentials: StoredCredentials) async throws -> StoredCredentials? {
        if let running = refreshTask {
            return try await running.value
        }
        let startedAt = generation
        let task = Task { try await self.performRefresh(credentials, startedAt: startedAt) }
        refreshTask = task
        return try await task.value
    }

    private func performRefresh(_ stale: StoredCredentials, startedAt: Int) async throws -> StoredCredentials? {
        defer {
            if generation == startedAt { refreshTask = nil }
        }
        guard let refreshToken = stale.tokens.refreshToken, !refreshToken.isEmpty else {
            // Nothing to renew the access token with: this session is over.
            dropCredentials()
            throw NoSlopError.notSignedIn
        }

        let response: JSON
        do {
            response = try await requestTokens([
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
                ("client_id", stale.clientID),
            ])
        } catch {
            guard generation == startedAt else { return nil }  // signed out meanwhile: the outcome no longer matters
            if let failure = error as? TokenEndpointFailure {
                if failure.code == "invalid_grant" {
                    dropCredentials()
                    throw NoSlopError.notSignedIn
                }
                throw failure.error
            }
            throw error
        }
        guard generation == startedAt else { return nil }

        // Google sends no new refresh token on a refresh; keep the one we have (and the rest) unless it says otherwise.
        let tokens = try Self.tokens(from: response, at: now(), keeping: stale.tokens)
        let refreshed = StoredCredentials(clientID: stale.clientID, tokens: tokens, account: stale.account)
        try store.save(refreshed)
        return refreshed
    }

    /// Removes the stored credentials and makes any refresh in flight discard its result.
    private func dropCredentials() {
        try? store.clear()
        supersedeRefreshInFlight()
    }

    private func supersedeRefreshInFlight() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: Network

    /// POSTs a form to the token endpoint. Non-2xx answers throw `TokenEndpointFailure`; transport errors propagate.
    private func requestTokens(_ fields: [(String, String)]) async throws -> JSON {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = GoogleURLEncoding.formBody(fields)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw TokenEndpointFailure(status: response.statusCode, body: data)
        }
        return try JSON(data: data)
    }

    /// The account for fresh tokens: from the `id_token` payload, else from the userinfo endpoint.
    private func account(for tokens: OAuthTokens) async throws -> GoogleAccount {
        if let account = GoogleAccountParser.account(fromIDToken: tokens.idToken) {
            return account
        }
        var request = URLRequest(url: Self.userInfoEndpoint)
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode) else { throw NoSlopError.http(status: response.statusCode) }
        guard let account = GoogleAccountParser.account(fromClaims: try JSON(data: data)) else {
            throw NoSlopError.oauth("could not read the account")
        }
        return account
    }

    private static func revoke(_ token: String, using http: any HTTPClient) async {
        let encoded = GoogleURLEncoding.percentEncode(token)
        guard let url = URL(string: "\(revokeEndpoint)?token=\(encoded)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = revokeTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()
        _ = try? await http.send(request)
    }

    // MARK: Parsing

    /// The authorization code in the redirect URL, after checking for an error and for the `state` we sent.
    private static func authorizationCode(in callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error"), !error.isEmpty {
            throw oauthError(error, description: value("error_description"))
        }
        guard value("state") == expectedState else { throw NoSlopError.oauth("state mismatch") }
        guard let code = value("code"), !code.isEmpty else { throw NoSlopError.oauth("no authorization code") }
        return code
    }

    /// Tokens from a token endpoint response. Fields the response leaves out are taken from `previous`.
    private static func tokens(from response: JSON, at now: Date, keeping previous: OAuthTokens?) throws -> OAuthTokens {
        guard let accessToken = response["access_token"]?.string, !accessToken.isEmpty else {
            throw NoSlopError.oauth("no access token in response")
        }
        let refreshToken = response["refresh_token"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.refreshToken
        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(lifetime(in: response)),
            scope: response["scope"]?.string ?? previous?.scope,
            idToken: response["id_token"]?.string ?? previous?.idToken
        )
    }

    /// How long the access token lives, from `expires_in`. A value that cannot be right (missing, not a number, not
    /// finite like "inf", not positive, or longer than `maximumTokenLifetime`) takes the default instead: the token is
    /// then renewed after an hour at the latest, and the expiry is always a date that can be stored (an infinite one
    /// cannot be encoded for the Keychain).
    private static func lifetime(in response: JSON) -> TimeInterval {
        guard let seconds = response["expires_in"]?.double, seconds.isFinite, seconds > 0, seconds <= maximumTokenLifetime else {
            return defaultTokenLifetime
        }
        return seconds
    }

    /// Whether the scopes in a token response (space-separated) include the YouTube scope, as a whole entry:
    /// "…/auth/youtube.readonly" is a different permission. A response without `scope` grants what was asked for.
    fileprivate static func grantsYouTubeAccess(_ scope: String?) -> Bool {
        guard let scope else { return true }
        return scope.split(whereSeparator: \.isWhitespace).contains { $0 == GoogleOAuthConfig.youTubeScope }
    }

    fileprivate static let youTubeAccessNotGranted = NoSlopError.oauth(
        "YouTube access wasn't granted. Sign in again and allow access to your YouTube account."
    )

    /// `.oauth("access_denied")`, or `.oauth("invalid_client: The OAuth client was not found.")` with a description.
    fileprivate static func oauthError(_ code: String, description: String?) -> NoSlopError {
        guard let description, !description.isEmpty else { return .oauth(code) }
        return .oauth("\(code): \(description.prefix(200))")
    }
}

/// A non-2xx answer from Google's token endpoint, with the OAuth error code from its JSON body when there is one.
private struct TokenEndpointFailure: Error {
    let status: Int
    let code: String?
    let message: String?

    init(status: Int, body: Data) {
        let json = try? JSON(data: body)
        self.status = status
        self.code = json?["error"]?.string
        self.message = json?["error_description"]?.string
    }

    /// `.oauth(code)` when Google named an error, else just the HTTP status.
    var error: NoSlopError {
        guard let code, !code.isEmpty else { return .http(status: status) }
        return GoogleOAuthService.oauthError(code, description: message)
    }
}

/// Internal seam (not part of the public contract) for `YouTubeDataAPIClient`: after the API answered 401 for a
/// token the clock still considered valid, ask for a different one.
protocol GoogleTokenRefreshing: GoogleAuthProviding {
    func refreshedAccessToken(replacing rejected: String) async throws -> String
}

extension GoogleOAuthService: GoogleTokenRefreshing {}
