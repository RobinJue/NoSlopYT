import Foundation
import Security
import Testing
@testable import NoSlopKit

// MARK: - Shared constants and helpers (file-private so they never clash with other tasks' tests)

private let testClientID = "123-abc.apps.googleusercontent.com"
private let testRedirectURI = "com.googleusercontent.apps.123-abc:/oauth2redirect"
private let tokenEndpoint = "oauth2.googleapis.com/token"
private let revokeEndpoint = "oauth2.googleapis.com/revoke"
private let userInfoEndpoint = "openidconnect.googleapis.com/v1/userinfo"
private let allScopes = "openid email profile https://www.googleapis.com/auth/youtube"

/// "Now" for every test: the service gets a fixed clock so expiry maths is exact.
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func credentials(
    access: String = "old-at",
    refresh: String? = "rt",
    expiresAt: Date,
    clientID: String = testClientID,
    account: GoogleAccount = GoogleAccount(id: "1234", email: "you@example.com", name: "You")
) -> StoredCredentials {
    StoredCredentials(
        clientID: clientID,
        tokens: OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, scope: allScopes, idToken: "hdr.payload.sig"),
        account: account
    )
}

private func expiredCredentials(refresh: String? = "rt", clientID: String = testClientID) -> StoredCredentials {
    credentials(refresh: refresh, expiresAt: t0.addingTimeInterval(-600), clientID: clientID)
}

private func freshCredentials() -> StoredCredentials {
    credentials(expiresAt: t0.addingTimeInterval(3000))
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// "<header>.<base64url(claims)>.sig", like the id_token Google returns.
private func makeIDToken(_ claims: JSON) throws -> String {
    let header = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
    return "\(header).\(base64URL(try claims.data())).c2ln"
}

private func tokenBody(
    accessToken: String = "at",
    expiresIn: Int = 3599,
    refreshToken: String? = "rt",
    idToken: String? = nil,
    scope: String? = allScopes
) throws -> Data {
    var object: [String: JSON] = ["access_token": .string(accessToken), "expires_in": .number(Double(expiresIn)), "token_type": "Bearer"]
    if let refreshToken { object["refresh_token"] = .string(refreshToken) }
    if let idToken { object["id_token"] = .string(idToken) }
    if let scope { object["scope"] = .string(scope) }
    return try JSON.object(object).data()
}

private func oauthErrorBody(_ code: String, description: String? = nil) throws -> Data {
    var object: [String: JSON] = ["error": .string(code)]
    if let description { object["error_description"] = .string(description) }
    return try JSON.object(object).data()
}

private func redirect(_ query: String) -> URL {
    URL(string: "\(testRedirectURI)?\(query)") ?? URL(fileURLWithPath: "/invalid")
}

private func queryValue(_ url: URL?, _ name: String) -> String? {
    guard let url else { return nil }
    return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

/// The decoded fields of an `application/x-www-form-urlencoded` request body.
private func formFields(of request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

private func requests(to match: String, in http: MockHTTPClient) -> [URLRequest] {
    http.requests.filter { $0.url?.absoluteString.contains(match) == true }
}

private func isOAuthError(_ error: any Error) -> Bool {
    if case NoSlopError.oauth = error { return true }
    return false
}

/// `signOut()` returns once the credentials are gone; the revoke request is sent in the background. Waits (at most
/// ten seconds, so a bug fails instead of hanging) until `count` revoke requests have reached the client.
private func waitForRevocations(_ count: Int = 1, in http: MockHTTPClient) async {
    for _ in 0..<2000 {
        if requests(to: revokeEndpoint, in: http).count >= count { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Set by one task, read by another.
private final class GoogleReturnFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Answers the sign-in page with whatever `reply` builds from the authorization URL, and records what it was shown.
@MainActor
private final class GoogleFakeAuthenticator: WebAuthenticating {
    private(set) var authorizationURLs: [URL] = []
    private(set) var callbackSchemes: [String] = []
    private let reply: @MainActor (URL) throws -> URL

    init(reply: @escaping @MainActor (URL) throws -> URL) {
        self.reply = reply
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        authorizationURLs.append(url)
        callbackSchemes.append(callbackScheme)
        return try reply(url)
    }
}

/// A sign-in page that stays open until the test finishes it.
@MainActor
private final class GoogleSuspendedAuthenticator: WebAuthenticating {
    private var continuation: CheckedContinuation<URL, any Error>?
    private(set) var started = false

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func fail(with error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Holds every request whose URL contains `match` until `release()`, so tests can overlap calls deterministically.
private final class GoogleGatedHTTPClient: HTTPClient, @unchecked Sendable {
    let inner: MockHTTPClient
    private let match: String
    private let lock = NSLock()
    private var held: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var arrivals = 0

    init(inner: MockHTTPClient, holding match: String) {
        self.inner = inner
        self.match = match
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.absoluteString.contains(match) == true {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    arrivals += 1
                    if isOpen { return true }
                    held.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return try await inner.send(request)
    }

    func release() {
        var waiting: [CheckedContinuation<Void, Never>] = []
        lock.withLock {
            isOpen = true
            waiting = held
            held = []
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Returns once `count` gated requests have arrived (or after ten seconds, so a bug fails instead of hanging).
    func waitForArrivals(_ count: Int) async {
        for _ in 0..<2000 {
            if lock.withLock({ arrivals }) >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A token store whose reads fail, like a Keychain that is locked or unreadable.
private final class GoogleFailingTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var clears = 0
    var clearCount: Int { lock.withLock { clears } }

    func load() throws -> StoredCredentials? { throw NoSlopError.oauth("keychain unavailable") }
    func save(_ credentials: StoredCredentials) throws { throw NoSlopError.oauth("keychain unavailable") }
    func clear() throws { lock.withLock { clears += 1 } }
}

/// A token store that reads fine but cannot write, like a Keychain without the right entitlement.
private final class GoogleReadOnlyTokenStore: TokenStoring, @unchecked Sendable {
    func load() throws -> StoredCredentials? { nil }
    func save(_ credentials: StoredCredentials) throws { throw NoSlopError.oauth("keychain read-only") }
    func clear() throws {}
}

private struct Rig {
    let http: MockHTTPClient
    let store: InMemoryTokenStore
    let service: GoogleOAuthService

    init(credentials: StoredCredentials? = nil) {
        let http = MockHTTPClient()
        let store = InMemoryTokenStore(credentials)
        self.http = http
        self.store = store
        self.service = GoogleOAuthService(http: http, store: store, now: { t0 })
    }

    var tokenRequests: [URLRequest] { requests(to: tokenEndpoint, in: http) }
}

// MARK: - Sign-in

@Suite struct GoogleOAuthServiceSignInTests {
    @Test @MainActor func signInExchangesCode() async throws {
        let rig = Rig()
        let idToken = try makeIDToken(["iss": "https://accounts.google.com", "sub": "1234", "email": "you@example.com", "name": "You", "picture": "https://p/x.jpg"])
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: idToken))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=4/abc&state=\(queryValue(url, "state") ?? "")") }

        let account = try await rig.service.signIn(clientID: " \(testClientID) ", authenticator: authenticator)

        #expect(account == GoogleAccount(id: "1234", email: "you@example.com", name: "You", pictureURL: URL(string: "https://p/x.jpg")))
        #expect(await rig.service.currentAccount() == account)

        // The web session got the PKCE authorization URL and the reversed-client-ID callback scheme.
        #expect(authenticator.callbackSchemes == ["com.googleusercontent.apps.123-abc"])
        let authorizationURL = try #require(authenticator.authorizationURLs.first)
        #expect(authorizationURL.host == "accounts.google.com")
        #expect(queryValue(authorizationURL, "client_id") == testClientID)
        #expect(queryValue(authorizationURL, "redirect_uri") == testRedirectURI)
        #expect(queryValue(authorizationURL, "code_challenge_method") == "S256")
        #expect(queryValue(authorizationURL, "scope") == allScopes)

        // One token request: a form-encoded POST that carries the authorization code and the PKCE verifier.
        let request = try #require(rig.tokenRequests.first)
        #expect(rig.tokenRequests.count == 1)
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=4%2Fabc"))
        #expect(body.contains("client_id=123-abc.apps.googleusercontent.com"))
        #expect(body.contains("redirect_uri=com.googleusercontent.apps.123-abc%3A%2Foauth2redirect"))
        let fields = formFields(of: request)
        #expect(fields["code"] == "4/abc")
        #expect(fields["redirect_uri"] == testRedirectURI)
        #expect(fields["client_secret"] == nil, "a public client never sends a secret")
        let verifier = try #require(fields["code_verifier"])
        #expect(verifier.count == 64)
        #expect(queryValue(authorizationURL, "code_challenge") == PKCE.challenge(for: verifier), "the challenge sent to Google is the one for the verifier that is exchanged")

        // What was stored.
        let stored = try #require(try rig.store.load())
        #expect(stored.clientID == testClientID)
        #expect(stored.account == account)
        #expect(stored.tokens.accessToken == "at")
        #expect(stored.tokens.refreshToken == "rt")
        #expect(stored.tokens.idToken == idToken)
        #expect(stored.tokens.scope == allScopes)
        #expect(stored.tokens.expiresAt == t0.addingTimeInterval(3599))
    }

    @Test @MainActor func theOrderOfParametersInTheRedirectDoesNotMatter() async throws {
        // Here the state comes before the code, and the code's slash is percent-encoded.
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "1"])))
        let authenticator = GoogleFakeAuthenticator { url in redirect("state=\(queryValue(url, "state") ?? "")&code=4%2Fabc") }
        _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        #expect(formFields(of: try #require(rig.tokenRequests.first))["code"] == "4/abc")
    }

    @Test @MainActor func everySignInUsesAFreshStateAndVerifier() async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "1"])))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)

        let states = authenticator.authorizationURLs.compactMap { queryValue($0, "state") }
        #expect(states.count == 2)
        #expect(Set(states).count == 2)
        #expect(states.allSatisfy { $0.count >= 32 })
        let verifiers = rig.tokenRequests.compactMap { formFields(of: $0)["code_verifier"] }
        #expect(Set(verifiers).count == 2)
    }

    @Test @MainActor func stateMismatchFails() async throws {
        let rig = Rig()
        let authenticator = GoogleFakeAuthenticator { _ in redirect("code=4/abc&state=WRONG") }
        await #expect {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        } throws: { isOAuthError($0) }
        #expect(rig.http.requests.isEmpty, "a forged callback must never reach the token endpoint")
        #expect(try rig.store.load() == nil)
    }

    @Test @MainActor func missingStateFails() async throws {
        let rig = Rig()
        let authenticator = GoogleFakeAuthenticator { _ in redirect("code=4/abc") }
        await #expect {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        } throws: { isOAuthError($0) }
        #expect(rig.http.requests.isEmpty)
    }

    @Test @MainActor func errorCallbackFails() async throws {
        let rig = Rig()
        let authenticator = GoogleFakeAuthenticator { _ in redirect("error=access_denied") }
        await #expect(throws: NoSlopError.oauth("access_denied")) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }
        #expect(rig.http.requests.isEmpty)
        #expect(try rig.store.load() == nil)
    }

    @Test @MainActor func errorCallbackWithStateAndDescriptionKeepsBoth() async throws {
        let rig = Rig()
        let authenticator = GoogleFakeAuthenticator { url in
            redirect("error=access_denied&error_description=The%20user%20said%20no&state=\(queryValue(url, "state") ?? "")")
        }
        await #expect(throws: NoSlopError.oauth("access_denied: The user said no")) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }
    }

    @Test @MainActor func callbackWithoutCodeFails() async throws {
        let rig = Rig()
        let authenticator = GoogleFakeAuthenticator { url in redirect("state=\(queryValue(url, "state") ?? "")") }
        await #expect {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        } throws: { isOAuthError($0) }
        #expect(rig.http.requests.isEmpty)
    }

    @Test(arguments: ["", "   ", "nope", "123-abc.googleusercontent.com"])
    @MainActor func malformedClientIDIsNotConfigured(clientID: String) async {
        let rig = Rig()
        let authenticator = GoogleFakeAuthenticator { _ in redirect("code=c") }
        await #expect(throws: NoSlopError.googleNotConfigured) {
            _ = try await rig.service.signIn(clientID: clientID, authenticator: authenticator)
        }
        #expect(authenticator.authorizationURLs.isEmpty, "no web page for a client ID that cannot work")
        #expect(rig.http.requests.isEmpty)
    }

    @Test @MainActor func aCancelledSessionPropagatesAndChangesNothing() async throws {
        let previous = freshCredentials()
        let rig = Rig(credentials: previous)
        let authenticator = GoogleFakeAuthenticator { _ in throw NoSlopError.cancelled }
        await #expect(throws: NoSlopError.cancelled) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }
        #expect(rig.http.requests.isEmpty)
        #expect(try rig.store.load() == previous, "backing out of a second sign-in keeps the first session")
    }

    @Test @MainActor func aRejectedCodeExchangeMapsToAnOAuthErrorAndKeepsThePreviousSession() async throws {
        let previous = freshCredentials()
        let rig = Rig(credentials: previous)
        rig.http.enqueue(tokenEndpoint, status: 400, body: try oauthErrorBody("invalid_grant", description: "Bad Request"))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=used&state=\(queryValue(url, "state") ?? "")") }
        await #expect(throws: NoSlopError.oauth("invalid_grant: Bad Request")) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }
        #expect(try rig.store.load() == previous)
    }

    @Test @MainActor func aTokenEndpointOutageMapsToHTTPStatus() async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, status: 503, body: Data("<html>Service Unavailable</html>".utf8))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        await #expect(throws: NoSlopError.http(status: 503)) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }
    }

    // MARK: Granted scopes

    private static let youTubeAccessRefused = NoSlopError.oauth(
        "YouTube access wasn't granted. Sign in again and allow access to your YouTube account."
    )

    @Test @MainActor func signInWithoutTheYouTubeScopeKeepsNothing() async throws {
        // The user unticked "manage your YouTube account" on the consent screen.
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "1", "email": "you@example.com"]), scope: "openid email profile"))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }

        await #expect(throws: Self.youTubeAccessRefused) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }

        #expect(try rig.store.load() == nil, "the credentials are not kept")
        #expect(await rig.service.currentAccount() == nil)
        #expect(rig.http.requests.count == 1, "only the code exchange went out: no account lookup either")
    }

    @Test @MainActor func theScopeRefusalReadsAsAPlainSentence() async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "1"]), scope: "openid email profile"))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        do {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
            Issue.record("the sign-in should have been refused")
        } catch {
            // What the alert shows: the sentence itself, not "Google sign-in failed (... account.)."
            let text = (error as? LocalizedError)?.errorDescription
            #expect(text == "YouTube access wasn't granted. Sign in again and allow access to your YouTube account.")
        }
    }

    @Test(arguments: [
        "openid email profile",
        "https://www.googleapis.com/auth/youtube.readonly",
        "openid https://www.googleapis.com/auth/youtube.force-ssl https://www.googleapis.com/auth/youtubepartner",
        "https://www.googleapis.com/auth/youtube/", "HTTPS://WWW.GOOGLEAPIS.COM/AUTH/YOUTUBE",
        "", "   ",
    ])
    @MainActor func onlyTheYouTubeScopeItselfCounts(scope: String) async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "1"]), scope: scope))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        await #expect(throws: Self.youTubeAccessRefused) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }
        #expect(try rig.store.load() == nil)
    }

    @Test(arguments: [
        allScopes,
        "https://www.googleapis.com/auth/youtube",
        "https://www.googleapis.com/auth/youtube openid",
        "openid  email\nprofile\thttps://www.googleapis.com/auth/youtube",
        "https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/youtube",
    ])
    @MainActor func theSessionIsKeptWhenTheYouTubeScopeIsAmongTheGrantedOnes(scope: String) async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "1"]), scope: scope))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        let account = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        #expect(account.id == "1")
        #expect(try rig.store.load()?.tokens.scope == scope)
    }

    @Test @MainActor func aResponseWithoutAScopeGrantsWhatWasAskedFor() async throws {
        // RFC 6749, 5.1: `scope` may be left out when it equals the requested scope.
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "1"]), scope: nil))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        #expect(try rig.store.load()?.tokens.scope == nil)
    }

    @Test @MainActor func aRefusedSignInKeepsThePreviousSession() async throws {
        let previous = freshCredentials()
        let rig = Rig(credentials: previous)
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "other"]), scope: "openid"))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        await #expect(throws: Self.youTubeAccessRefused) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }
        #expect(try rig.store.load() == previous)
        #expect(await rig.service.currentAccount() == previous.account)
    }

    // MARK: Token lifetime

    private func bodyWithExpiry(_ expiresIn: JSON?, idToken: String) throws -> Data {
        var object: [String: JSON] = ["access_token": "at", "refresh_token": "rt", "token_type": "Bearer", "scope": .string(allScopes), "id_token": .string(idToken)]
        object["expires_in"] = expiresIn
        return try JSON.object(object).data()
    }

    @Test(arguments: [
        JSON.string("inf"), "-inf", "nan", "Infinity", "-Infinity", "0", "-5", "99999999999", "1e30", "soon", "",
        .number(0), .number(-1), .number(1e30), .number(2_592_001), .bool(true), .null, .array([]), .object([:]),
    ])
    @MainActor func anExpiryThatCannotBeRightTakesTheDefaultHour(expiresIn: JSON) async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try bodyWithExpiry(expiresIn, idToken: try makeIDToken(["sub": "1"])))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }

        _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)

        let stored = try #require(try rig.store.load())
        #expect(stored.tokens.expiresAt == t0.addingTimeInterval(3600))
        // An infinite expiry made the Keychain store fail to encode the credentials.
        _ = try JSONEncoder().encode(stored)
        _ = try JSONDecoder().decode(StoredCredentials.self, from: JSONEncoder().encode(stored))
    }

    @Test(arguments: [(JSON.number(3599), 3599.0), (.string("7200"), 7200), (.number(1), 1), (.number(2_592_000), 2_592_000), (.number(3599.5), 3599.5)])
    @MainActor func aPlausibleExpiryIsUsed(expiresIn: JSON, seconds: Double) async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try bodyWithExpiry(expiresIn, idToken: try makeIDToken(["sub": "1"])))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        #expect(try rig.store.load()?.tokens.expiresAt == t0.addingTimeInterval(seconds))
    }

    @Test @MainActor func aMissingExpiresInOnSignInDefaultsToAnHourToo() async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try bodyWithExpiry(nil, idToken: try makeIDToken(["sub": "1"])))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        #expect(try rig.store.load()?.tokens.expiresAt == t0.addingTimeInterval(3600))
    }

    @Test @MainActor func aTokenResponseWithoutAnAccessTokenFails() async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: Data(#"{"token_type":"Bearer"}"#.utf8))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        await #expect {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        } throws: { isOAuthError($0) }
        #expect(try rig.store.load() == nil)
    }

    @Test @MainActor func transportErrorsOnTheExchangePropagate() async throws {
        let rig = Rig()
        rig.http.enqueueError(tokenEndpoint, NoSlopError.network("offline"))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }
    }

    @Test(arguments: ["A", "Zo\u{00EB}", "Zo\u{00EB} M\u{00FC}ller", "Zo\u{00EB} M\u{00FC}ller \u{1F3A7}"])
    @MainActor func idTokenClaimsDecodeForEveryBase64Padding(name: String) async throws {
        // Payload lengths that need 0, 1 and 2 "=" characters once the base64url padding is restored.
        let rig = Rig()
        let idToken = try makeIDToken(["sub": "42", "email": "a@b.c", "name": .string(name), "picture": .string("https://p/\(name.count).jpg")])
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: idToken))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        let account = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        #expect(account.id == "42")
        #expect(account.name == name)
        #expect(account.email == "a@b.c")
        #expect(account.pictureURL == URL(string: "https://p/\(name.count).jpg"))
    }

    @Test @MainActor func theAccountFallsBackToTheUserInfoEndpointWithoutAnIDToken() async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: nil))
        rig.http.enqueue(userInfoEndpoint, body: Data(#"{"sub":"777","name":"Info User","picture":"https://p/i.jpg","email":"info@example.com"}"#.utf8))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }

        let account = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)

        #expect(account == GoogleAccount(id: "777", email: "info@example.com", name: "Info User", pictureURL: URL(string: "https://p/i.jpg")))
        let infoRequest = try #require(requests(to: userInfoEndpoint, in: rig.http).first)
        #expect(infoRequest.httpMethod == "GET")
        #expect(infoRequest.value(forHTTPHeaderField: "Authorization") == "Bearer at")
        #expect(try rig.store.load()?.account == account)
    }

    @Test(arguments: ["not-a-jwt", "a.b", "a.%%%.c", "a.bm90IGpzb24.c", "a.e30.c"])
    @MainActor func aBrokenIDTokenFallsBackToTheUserInfoEndpoint(idToken: String) async throws {
        // "e30" is "{}": a valid payload without a subject.
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: idToken))
        rig.http.enqueue(userInfoEndpoint, body: Data(#"{"sub":"777"}"#.utf8))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        let account = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        #expect(account.id == "777")
    }

    @Test @MainActor func signInFailsWhenNoAccountCanBeIdentified() async throws {
        let rig = Rig()
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: nil))
        rig.http.enqueue(userInfoEndpoint, status: 401, body: Data("{}".utf8))
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        await #expect(throws: NoSlopError.http(status: 401)) {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: authenticator)
        }
        #expect(try rig.store.load() == nil, "half a sign-in is never stored")
    }

    @Test @MainActor func aStoreThatCannotWriteFailsTheSignIn() async throws {
        let http = MockHTTPClient()
        http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "1"])))
        let service = GoogleOAuthService(http: http, store: GoogleReadOnlyTokenStore(), now: { t0 })
        let authenticator = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        await #expect(throws: NoSlopError.oauth("keychain read-only")) {
            _ = try await service.signIn(clientID: testClientID, authenticator: authenticator)
        }
    }

    @Test @MainActor func aSecondSignInWhileOneIsRunningIsRejected() async throws {
        let rig = Rig()
        let pending = GoogleSuspendedAuthenticator()
        let first = Task { try await rig.service.signIn(clientID: testClientID, authenticator: pending) }
        for _ in 0..<2000 where !pending.started { try await Task.sleep(for: .milliseconds(5)) }
        #expect(pending.started)

        let other = GoogleFakeAuthenticator { _ in throw NoSlopError.cancelled }
        await #expect {
            _ = try await rig.service.signIn(clientID: testClientID, authenticator: other)
        } throws: { isOAuthError($0) }
        #expect(other.authorizationURLs.isEmpty)

        pending.fail(with: NoSlopError.cancelled)
        await #expect(throws: NoSlopError.cancelled) { _ = try await first.value }

        // The guard is released again: a normal sign-in works afterwards.
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(idToken: try makeIDToken(["sub": "9"])))
        let again = GoogleFakeAuthenticator { url in redirect("code=c&state=\(queryValue(url, "state") ?? "")") }
        #expect(try await rig.service.signIn(clientID: testClientID, authenticator: again).id == "9")
    }
}

// MARK: - Access tokens and refresh

@Suite struct GoogleOAuthServiceRefreshTests {
    @Test func withoutCredentialsThereIsNoAccessToken() async {
        let rig = Rig()
        await #expect(throws: NoSlopError.notSignedIn) { _ = try await rig.service.accessToken() }
        #expect(rig.http.requests.isEmpty)
        #expect(await rig.service.currentAccount() == nil)
    }

    @Test(arguments: [(61.0, false), (3000.0, false), (59.0, true), (0.0, true), (-5.0, true)])
    func aTokenIsRefreshedOnceItIsWithinAMinuteOfExpiry(secondsUntilExpiry: Double, refreshes: Bool) async throws {
        let rig = Rig(credentials: credentials(expiresAt: t0.addingTimeInterval(secondsUntilExpiry)))
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(accessToken: "new-at", refreshToken: nil))
        let token = try await rig.service.accessToken()
        #expect(token == (refreshes ? "new-at" : "old-at"))
        #expect(rig.tokenRequests.count == (refreshes ? 1 : 0))
    }

    @Test func refreshWhenExpired() async throws {
        let original = expiredCredentials()
        let rig = Rig(credentials: original)
        // Google's refresh response carries no refresh_token.
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(accessToken: "new-at", expiresIn: 3599, refreshToken: nil))

        let token = try await rig.service.accessToken()

        #expect(token == "new-at")
        let request = try #require(rig.tokenRequests.first)
        #expect(rig.tokenRequests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let fields = formFields(of: request)
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["refresh_token"] == "rt")
        #expect(fields["client_id"] == testClientID)
        #expect(fields["client_secret"] == nil)

        let stored = try #require(try rig.store.load())
        #expect(stored.tokens.accessToken == "new-at")
        #expect(stored.tokens.refreshToken == "rt", "the refresh token is kept when the response omits it")
        #expect(stored.tokens.expiresAt == t0.addingTimeInterval(3599))
        #expect(stored.tokens.idToken == original.tokens.idToken)
        #expect(stored.account == original.account)
        #expect(stored.clientID == original.clientID)

        // The new token is now valid, so the next call needs no network at all.
        #expect(try await rig.service.accessToken() == "new-at")
        #expect(rig.tokenRequests.count == 1)
    }

    @Test func aRotatedRefreshTokenReplacesTheOldOne() async throws {
        let rig = Rig(credentials: expiredCredentials())
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(accessToken: "new-at", refreshToken: "rt2"))
        _ = try await rig.service.accessToken()
        #expect(try rig.store.load()?.tokens.refreshToken == "rt2")
    }

    @Test func aRefreshUsesTheClientIDTheCredentialsWereIssuedTo() async throws {
        let rig = Rig(credentials: expiredCredentials(clientID: "999-zzz.apps.googleusercontent.com"))
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(accessToken: "new-at", refreshToken: nil))
        _ = try await rig.service.accessToken()
        #expect(formFields(of: try #require(rig.tokenRequests.first))["client_id"] == "999-zzz.apps.googleusercontent.com")
        #expect(try rig.store.load()?.clientID == "999-zzz.apps.googleusercontent.com")
    }

    @Test func aMissingExpiresInDefaultsToAnHour() async throws {
        let rig = Rig(credentials: expiredCredentials())
        rig.http.enqueue(tokenEndpoint, body: Data(#"{"access_token":"new-at"}"#.utf8))
        _ = try await rig.service.accessToken()
        #expect(try rig.store.load()?.tokens.expiresAt == t0.addingTimeInterval(3600))
    }

    @Test(arguments: [JSON.string("inf"), "nan", "-1", .number(0), .number(1e30), .null])
    func aRefreshWithAnExpiryThatCannotBeRightTakesTheDefaultHour(expiresIn: JSON) async throws {
        let rig = Rig(credentials: expiredCredentials())
        var object: [String: JSON] = ["access_token": "new-at", "token_type": "Bearer"]
        object["expires_in"] = expiresIn
        rig.http.enqueue(tokenEndpoint, body: try JSON.object(object).data())

        #expect(try await rig.service.accessToken() == "new-at")

        let stored = try #require(try rig.store.load())
        #expect(stored.tokens.expiresAt == t0.addingTimeInterval(3600))
        _ = try JSONEncoder().encode(stored)
    }

    @Test func concurrentAccessTokenRefreshesOnce() async throws {
        let mock = MockHTTPClient()
        mock.enqueue(tokenEndpoint, body: try tokenBody(accessToken: "new-at", refreshToken: nil))
        let gate = GoogleGatedHTTPClient(inner: mock, holding: tokenEndpoint)
        let store = InMemoryTokenStore(expiredCredentials())
        let service = GoogleOAuthService(http: gate, store: store, now: { t0 })

        let first = Task { try await service.accessToken() }
        await gate.waitForArrivals(1)  // the first caller is now parked inside the token request
        let second = Task { try await service.accessToken() }
        let third = Task { try await service.accessToken() }
        try await Task.sleep(for: .milliseconds(100))  // let the others reach the actor and join the refresh in flight
        gate.release()

        #expect(try await first.value == "new-at")
        #expect(try await second.value == "new-at")
        #expect(try await third.value == "new-at")
        #expect(requests(to: tokenEndpoint, in: mock).count == 1)
    }

    @Test func invalidGrantSignsOut() async throws {
        let rig = Rig(credentials: expiredCredentials())
        rig.http.enqueue(tokenEndpoint, status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))

        await #expect(throws: NoSlopError.notSignedIn) { _ = try await rig.service.accessToken() }

        #expect(try rig.store.load() == nil)
        #expect(await rig.service.currentAccount() == nil)
        // Signed out for good: no further token requests are attempted.
        await #expect(throws: NoSlopError.notSignedIn) { _ = try await rig.service.accessToken() }
        #expect(rig.tokenRequests.count == 1)
    }

    @Test func aRefreshThatFailsOnTheNetworkKeepsTheCredentialsAndCanBeRetried() async throws {
        let original = expiredCredentials()
        let rig = Rig(credentials: original)
        rig.http.enqueueError(tokenEndpoint, NoSlopError.network("offline"))
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(accessToken: "new-at", refreshToken: nil))

        await #expect(throws: NoSlopError.network("offline")) { _ = try await rig.service.accessToken() }
        #expect(try rig.store.load() == original, "going offline must not sign the user out")
        #expect(await rig.service.currentAccount() == original.account)

        // The failed attempt left nothing stuck: the next call refreshes normally.
        #expect(try await rig.service.accessToken() == "new-at")
        #expect(rig.tokenRequests.count == 2)
    }

    @Test(arguments: [500, 502, 503])
    func aServerErrorOnRefreshKeepsTheCredentials(status: Int) async throws {
        let original = expiredCredentials()
        let rig = Rig(credentials: original)
        rig.http.enqueue(tokenEndpoint, status: status, body: Data("<html>oops</html>".utf8))
        await #expect(throws: NoSlopError.http(status: status)) { _ = try await rig.service.accessToken() }
        #expect(try rig.store.load() == original)
    }

    @Test func otherOAuthErrorsOnRefreshAreReportedWithoutSigningOut() async throws {
        let original = expiredCredentials()
        let rig = Rig(credentials: original)
        rig.http.enqueue(tokenEndpoint, status: 401, body: try oauthErrorBody("invalid_client", description: "The OAuth client was not found."))
        await #expect(throws: NoSlopError.oauth("invalid_client: The OAuth client was not found.")) { _ = try await rig.service.accessToken() }
        #expect(try rig.store.load() == original, "a wrong Settings entry must not destroy a working session")
    }

    @Test func expiredCredentialsWithoutARefreshTokenSignOut() async throws {
        let rig = Rig(credentials: expiredCredentials(refresh: nil))
        await #expect(throws: NoSlopError.notSignedIn) { _ = try await rig.service.accessToken() }
        #expect(rig.http.requests.isEmpty, "nothing to refresh with, so no request")
        #expect(try rig.store.load() == nil)
    }

    @Test func aRefreshResponseWithoutAnAccessTokenIsAnErrorAndKeepsTheCredentials() async throws {
        let original = expiredCredentials()
        let rig = Rig(credentials: original)
        rig.http.enqueue(tokenEndpoint, body: Data("{}".utf8))
        await #expect {
            _ = try await rig.service.accessToken()
        } throws: { isOAuthError($0) }
        #expect(try rig.store.load() == original)
    }

    @Test func aStoreThatCannotBeReadIsReportedAndNeverCleared() async throws {
        let store = GoogleFailingTokenStore()
        let http = MockHTTPClient()
        let service = GoogleOAuthService(http: http, store: store, now: { t0 })
        #expect(await service.currentAccount() == nil)
        await #expect(throws: NoSlopError.oauth("keychain unavailable")) { _ = try await service.accessToken() }
        #expect(store.clearCount == 0, "a transient read failure must not wipe the credentials")
        #expect(http.requests.isEmpty)
    }

    @Test func currentAccountComesFromTheStoreWithoutTheNetwork() async {
        let rig = Rig(credentials: freshCredentials())
        #expect(await rig.service.currentAccount() == GoogleAccount(id: "1234", email: "you@example.com", name: "You"))
        #expect(rig.http.requests.isEmpty)
    }

    // MARK: Refreshing after the API rejected a token (used by YouTubeDataAPIClient on HTTP 401)

    @Test func refreshedAccessTokenReplacesATokenTheAPIRejected() async throws {
        let rig = Rig(credentials: freshCredentials())  // valid by the clock, but the server said 401
        rig.http.enqueue(tokenEndpoint, body: try tokenBody(accessToken: "new-at", refreshToken: nil))

        #expect(try await rig.service.refreshedAccessToken(replacing: "old-at") == "new-at")
        #expect(rig.tokenRequests.count == 1)

        // A second request that was rejected with the same old token must not trigger another refresh.
        #expect(try await rig.service.refreshedAccessToken(replacing: "old-at") == "new-at")
        #expect(rig.tokenRequests.count == 1)
    }

    @Test func refreshedAccessTokenWithoutCredentialsIsNotSignedIn() async {
        let rig = Rig()
        await #expect(throws: NoSlopError.notSignedIn) { _ = try await rig.service.refreshedAccessToken(replacing: "x") }
    }

    @Test func refreshedAccessTokenSignsOutOnInvalidGrant() async throws {
        let rig = Rig(credentials: freshCredentials())
        rig.http.enqueue(tokenEndpoint, status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
        await #expect(throws: NoSlopError.notSignedIn) { _ = try await rig.service.refreshedAccessToken(replacing: "old-at") }
        #expect(try rig.store.load() == nil)
    }
}

// MARK: - Sign-out

@Suite struct GoogleOAuthServiceSignOutTests {
    @Test func signOutRevokes() async throws {
        let rig = Rig(credentials: freshCredentials())
        rig.http.enqueue(revokeEndpoint, body: Data("{}".utf8))

        await rig.service.signOut()
        await waitForRevocations(in: rig.http)

        let revocations = requests(to: revokeEndpoint, in: rig.http)
        #expect(revocations.count == 1)
        let request = try #require(revocations.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/revoke?token=rt", "the refresh token is revoked: that ends the whole grant")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(try rig.store.load() == nil)
        #expect(await rig.service.currentAccount() == nil)
        await #expect(throws: NoSlopError.notSignedIn) { _ = try await rig.service.accessToken() }
    }

    @Test func theAccessTokenIsRevokedWhenThereIsNoRefreshToken() async throws {
        let rig = Rig(credentials: credentials(refresh: nil, expiresAt: t0.addingTimeInterval(3000)))
        rig.http.enqueue(revokeEndpoint, body: Data("{}".utf8))
        await rig.service.signOut()
        await waitForRevocations(in: rig.http)
        #expect(requests(to: revokeEndpoint, in: rig.http).first?.url?.absoluteString == "https://oauth2.googleapis.com/revoke?token=old-at")
    }

    @Test func theRevokedTokenIsPercentEncoded() async throws {
        let rig = Rig(credentials: credentials(refresh: "fake/rt with+plus=eq&amp#hash", expiresAt: t0.addingTimeInterval(3000)))
        rig.http.enqueue(revokeEndpoint, body: Data("{}".utf8))
        await rig.service.signOut()
        await waitForRevocations(in: rig.http)
        let request = try #require(requests(to: revokeEndpoint, in: rig.http).first)
        #expect(queryValue(request.url, "token") == "fake/rt with+plus=eq&amp#hash")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems?.count == 1)
    }

    @Test func signOutClearsTheStoreEvenIfRevokingFails() async throws {
        let rig = Rig(credentials: freshCredentials())
        rig.http.enqueueError(revokeEndpoint, NoSlopError.network("offline"))
        await rig.service.signOut()
        await waitForRevocations(in: rig.http)
        #expect(requests(to: revokeEndpoint, in: rig.http).count == 1)
        #expect(try rig.store.load() == nil)
        #expect(await rig.service.currentAccount() == nil)
    }

    @Test func signOutClearsTheStoreEvenIfGoogleRejectsTheRevocation() async throws {
        let rig = Rig(credentials: freshCredentials())
        rig.http.enqueue(revokeEndpoint, status: 400, body: try oauthErrorBody("invalid_token"))
        await rig.service.signOut()
        #expect(try rig.store.load() == nil)
    }

    @Test func signOutDoesNotWaitForGoogleToAnswerTheRevocation() async throws {
        // On a slow connection the revoke request takes up to its ten second timeout. The viewer is signed out as soon as
        // the credentials are gone, so signing out must return then, with the request still on its way.
        let mock = MockHTTPClient()
        mock.enqueue(revokeEndpoint, body: Data("{}".utf8))
        let gate = GoogleGatedHTTPClient(inner: mock, holding: revokeEndpoint)
        let store = InMemoryTokenStore(freshCredentials())
        let service = GoogleOAuthService(http: gate, store: store, now: { t0 })

        let returned = GoogleReturnFlag()
        let signingOut = Task {
            await service.signOut()
            returned.set()
        }
        await gate.waitForArrivals(1)  // the revoke request is out, and Google has not answered
        for _ in 0..<200 where !returned.isSet {
            try await Task.sleep(for: .milliseconds(5))
        }
        let returnedWhileTheRequestWasHeld = returned.isSet
        let credentialsGoneWhileTheRequestWasHeld = try store.load() == nil
        gate.release()  // ...so that a signOut that does wait finishes too
        await signingOut.value

        #expect(returnedWhileTheRequestWasHeld, "signOut waited for Google's answer")
        #expect(credentialsGoneWhileTheRequestWasHeld)
        #expect(await service.currentAccount() == nil)
        await waitForRevocations(in: mock)
        #expect(requests(to: revokeEndpoint, in: mock).count == 1, "the revocation is still sent")
    }

    @Test func signOutWithoutCredentialsDoesNothing() async {
        let rig = Rig()
        await rig.service.signOut()
        #expect(rig.http.requests.isEmpty)
    }

    @Test func signOutDuringARefreshKeepsTheUserSignedOut() async throws {
        let mock = MockHTTPClient()
        mock.enqueue(tokenEndpoint, body: try tokenBody(accessToken: "new-at", refreshToken: nil))
        mock.enqueue(revokeEndpoint, body: Data("{}".utf8))
        let gate = GoogleGatedHTTPClient(inner: mock, holding: tokenEndpoint)
        let store = InMemoryTokenStore(expiredCredentials())
        let service = GoogleOAuthService(http: gate, store: store, now: { t0 })

        let pending = Task { try await service.accessToken() }
        await gate.waitForArrivals(1)  // the refresh is in flight
        await service.signOut()
        gate.release()  // ...and only now does Google answer

        await #expect(throws: NoSlopError.notSignedIn) { _ = try await pending.value }
        #expect(try store.load() == nil, "a late refresh result must not resurrect a signed-out session")
        #expect(await service.currentAccount() == nil)
        await #expect(throws: NoSlopError.notSignedIn) { _ = try await service.accessToken() }
    }
}

// MARK: - Token stores

@Suite struct GoogleOAuthServiceInMemoryStoreTests {
    @Test func startsEmptyOrWithTheInitialValue() throws {
        #expect(try InMemoryTokenStore().load() == nil)
        let initial = freshCredentials()
        #expect(try InMemoryTokenStore(initial).load() == initial)
    }

    @Test func saveLoadClearRoundTrip() throws {
        let store = InMemoryTokenStore()
        let first = freshCredentials()
        try store.save(first)
        #expect(try store.load() == first)
        let second = credentials(access: "other", refresh: nil, expiresAt: t0)
        try store.save(second)
        #expect(try store.load() == second)
        try store.clear()
        #expect(try store.load() == nil)
        try store.clear()  // clearing an empty store is fine
        #expect(try store.load() == nil)
    }

    @Test func storesDoNotShareState() throws {
        let a = InMemoryTokenStore()
        let b = InMemoryTokenStore()
        try a.save(freshCredentials())
        #expect(try b.load() == nil)
    }

    @Test func isSafeToUseFromManyTasksAtOnce() async throws {
        let store = InMemoryTokenStore()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let value = credentials(access: "at-\(index)", expiresAt: t0)
                    try? store.save(value)
                    _ = try? store.load()
                    if index % 10 == 0 { try? store.clear() }
                }
            }
        }
        // Whatever the interleaving was, the store holds either nothing or one complete value.
        if let stored = try store.load() {
            #expect(stored.tokens.accessToken.hasPrefix("at-"))
        }
    }
}

/// The real Keychain, through the macOS login keychain. Items live under a unique service name per test and are
/// removed again; the data-protection keychain (which needs an entitlement) is deliberately not used.
///
/// Set `NOSLOP_SKIP_KEYCHAIN_TESTS=1` to skip these tests on a machine where the Keychain asks for a password.
@Suite(.enabled(if: KeychainAvailability.isUsable, "The Keychain is not usable in this environment."), .timeLimit(.minutes(2)))
struct GoogleOAuthServiceKeychainStoreTests {
    private func makeStore() -> (store: KeychainTokenStore, service: String) {
        let service = "com.robinjungerich.noslopyt.tests.\(UUID().uuidString)"
        return (KeychainTokenStore(service: service), service)
    }

    /// The raw bytes of the item, bypassing `KeychainTokenStore`.
    private func rawItem(service: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "credentials",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @Test func saveLoadClearRoundTrip() throws {
        let (store, _) = makeStore()
        defer { try? store.clear() }

        #expect(try store.load() == nil)
        let first = credentials(access: "at-1", refresh: "rt-1", expiresAt: t0.addingTimeInterval(3599))
        try store.save(first)
        #expect(try store.load() == first)

        let second = credentials(access: "at-2", refresh: nil, expiresAt: t0.addingTimeInterval(10))
        try store.save(second)  // overwrites in place
        #expect(try store.load() == second)

        try store.clear()
        #expect(try store.load() == nil)
        try store.clear()  // clearing again is not an error
    }

    @Test func theItemIsTheJSONEncodedCredentialsUnderTheDocumentedAccount() throws {
        let (store, service) = makeStore()
        defer { try? store.clear() }
        let value = credentials(access: "at-json", expiresAt: t0)
        try store.save(value)
        let raw = try #require(rawItem(service: service))
        #expect(try JSONDecoder().decode(StoredCredentials.self, from: raw) == value)
    }

    @Test func dateAndURLValuesSurviveTheRoundTripExactly() throws {
        let (store, _) = makeStore()
        defer { try? store.clear() }
        var value = credentials(expiresAt: Date(timeIntervalSince1970: 1_800_000_123.456))
        value.account.pictureURL = URL(string: "https://lh3.googleusercontent.com/a/x=s96-c")
        try store.save(value)
        let loaded = try #require(try store.load())
        #expect(loaded == value)
        #expect(loaded.tokens.expiresAt == value.tokens.expiresAt)
    }

    @Test func differentServicesAreIsolated() throws {
        let (a, _) = makeStore()
        let (b, _) = makeStore()
        defer { try? a.clear(); try? b.clear() }
        try a.save(credentials(access: "only-a", expiresAt: t0))
        #expect(try b.load() == nil)
        try b.save(credentials(access: "only-b", expiresAt: t0))
        try a.clear()
        #expect(try a.load() == nil)
        #expect(try b.load()?.tokens.accessToken == "only-b")
    }

    @Test func anUnreadableItemThrowsAndIsRepairedByTheNextSave() throws {
        let (store, service) = makeStore()
        defer { try? store.clear() }
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "credentials",
            kSecValueData: Data("this is not json".utf8),
        ]
        #expect(SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess)

        #expect(throws: NoSlopError.self) { _ = try store.load() }

        let repaired = credentials(access: "fixed", expiresAt: t0)
        try store.save(repaired)
        #expect(try store.load() == repaired)
    }

    @Test func aServiceWorksWithAGoogleOAuthServiceEndToEnd() async throws {
        let (store, _) = makeStore()
        defer { try? store.clear() }
        try store.save(expiredCredentials())
        let http = MockHTTPClient()
        http.enqueue(tokenEndpoint, body: try tokenBody(accessToken: "new-at", refreshToken: nil))
        http.enqueue(revokeEndpoint, body: Data("{}".utf8))
        let service = GoogleOAuthService(http: http, store: store, now: { t0 })

        #expect(try await service.accessToken() == "new-at")
        #expect(try store.load()?.tokens.accessToken == "new-at")
        await service.signOut()
        #expect(try store.load() == nil)
    }
}

/// Probes the Keychain once: can this process add, read and delete an item without any prompt?
private enum KeychainAvailability {
    static let isUsable: Bool = {
        if ProcessInfo.processInfo.environment["NOSLOP_SKIP_KEYCHAIN_TESTS"] == "1" { return false }
        let store = KeychainTokenStore(service: "com.robinjungerich.noslopyt.tests.probe.\(UUID().uuidString)")
        defer { try? store.clear() }
        let probe = credentials(access: "probe", expiresAt: t0)
        do {
            try store.save(probe)
            return try store.load() == probe
        } catch {
            return false
        }
    }()
}
