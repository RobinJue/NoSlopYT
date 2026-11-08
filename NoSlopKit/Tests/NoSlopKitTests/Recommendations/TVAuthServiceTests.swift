import Foundation
import Testing
@testable import NoSlopKit

/// Every value here is made up (names start with tvsynthetic_); nothing is a real client pair, token or code.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private var slept: [Int] = []

    var now: Date { lock.withLock { current } }
    var sleeps: [Int] { lock.withLock { slept } }

    func advance(_ seconds: Double) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    /// Records the wait and moves the clock by it, as a real sleep would.
    func sleep(_ duration: Duration) {
        let seconds = Int(duration.components.seconds)
        lock.withLock {
            slept.append(seconds)
            current = current.addingTimeInterval(Double(seconds))
        }
    }
}

/// Holds the token reply until `release()`, so a test can disconnect while a refresh is in flight.
private final class GatedHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var reached: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var tokenRequestSeen = false
    private var released = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        if url.absoluteString.contains("oauth2/token") {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resume: [CheckedContinuation<Void, Never>] = lock.withLock {
                    tokenRequestSeen = true
                    var waiting: [CheckedContinuation<Void, Never>] = []
                    if let reached { waiting.append(reached); self.reached = nil }
                    if released { waiting.append(continuation) } else { gate = continuation }
                    return waiting
                }
                resume.forEach { $0.resume() }
            }
            let body = Data(#"{"access_token":"tvsynthetic_access_late","refresh_token":"tvsynthetic_refresh_late","expires_in":3599}"#.utf8)
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        // Revoke calls: answer 200.
        return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }

    func waitForTokenRequest() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if tokenRequestSeen { return true }
                reached = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            let g = gate
            gate = nil
            return g
        }
        waiting?.resume()
    }
}

private struct Rig {
    let http = MockHTTPClient()
    let store = InMemoryTVTokenStore()
    let suite = "tvsynthetic.\(UUID().uuidString)"
    /// A second handle on the suite the service writes to.
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    let clock = TestClock()
    let service: TVAuthService

    init(credentials: TVCredentials? = nil) {
        if let credentials { try? store.save(credentials) }
        let clock = self.clock
        service = TVAuthService(
            http: http,
            store: store,
            defaults: UserDefaults(suiteName: suite)!,
            now: { clock.now },
            sleep: { clock.sleep($0) }
        )
    }

    func queueClientValues(script: String = #"var a={clientId:"tvsynthetic_client_1",secret:"tvsynthetic_secret_1"};"#) {
        http.enqueue("www.youtube.com/tv", body: Data(#"<html><script nonce="n" id="base-js" src="/s/tv/m=base"></script></html>"#.utf8))
        http.enqueue("/s/tv/m=base", body: Data(script.utf8))
    }

    func queueDeviceCode(interval: Int = 5, expiresIn: Int = 1800) {
        http.enqueue("oauth2/device/code", body: Data("""
        {"device_code":"tvsynthetic_device_code","user_code":"ABC-DEF-GHI","verification_url":"https://www.google.com/device","expires_in":\(expiresIn),"interval":\(interval)}
        """.utf8))
    }

    func queueToken(_ body: String, status: Int = 200) {
        http.enqueue("oauth2/token", status: status, body: Data(body.utf8))
    }

    var firstTokenBody: JSON? { tokenRequests.first.flatMap { http.bodyJSON(of: $0) } }

    var tokenRequests: [URLRequest] { http.requests.filter { $0.url?.absoluteString.contains("oauth2/token") == true } }
}

private let success = """
{"access_token":"tvsynthetic_access_1","refresh_token":"tvsynthetic_refresh_1","expires_in":3599,"scope":"tvsynthetic_scope","token_type":"Bearer"}
"""

private func stored(expiresIn: Double, clock: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> TVCredentials {
    TVCredentials(
        accessToken: "tvsynthetic_access_old",
        refreshToken: "tvsynthetic_refresh_old",
        expiresAt: clock.addingTimeInterval(expiresIn),
        scope: "tvsynthetic_scope",
        clientID: "tvsynthetic_client_1",
        clientSecret: "tvsynthetic_secret_1",
        accountName: "Synthetic Name",
        connectedAt: clock.addingTimeInterval(-86_400)
    )
}

@Suite struct TVAuthServiceTests {
    @Test func theFirstClientPairWins() async throws {
        let rig = Rig()
        rig.queueClientValues(script: #"x={clientId:"tvsynthetic_first",secret:"tvsynthetic_first_secret"};y={clientId:"tvsynthetic_second",secret:"tvsynthetic_second_secret"};"#)
        rig.queueDeviceCode()
        rig.queueToken(success)
        let prompt = try await rig.service.beginSignIn()
        _ = try await rig.service.completeSignIn(prompt)

        let credentials = try #require(try rig.store.load())
        #expect(credentials.clientID == "tvsynthetic_first")
        #expect(credentials.clientSecret == "tvsynthetic_first_secret")
        let tokenBody = try #require(rig.firstTokenBody)
        #expect(tokenBody["client_id"]?.string == "tvsynthetic_first")
        #expect(tokenBody["client_secret"]?.string == "tvsynthetic_first_secret")
        #expect(tokenBody["code"]?.string == "tvsynthetic_device_code")
        #expect(tokenBody["grant_type"]?.string == "http://oauth.net/grant_type/device/1.0")
    }

    @Test func theCodeRequestAndThePromptHaveTheDocumentedShape() async throws {
        let rig = Rig()
        rig.queueClientValues()
        rig.queueDeviceCode()
        let prompt = try await rig.service.beginSignIn()

        #expect(prompt.userCode == "ABC-DEF-GHI")
        #expect(prompt.verificationURL.absoluteString == "https://www.google.com/device?user_code=ABC-DEF-GHI")
        #expect(prompt.expiresAt == rig.clock.now.addingTimeInterval(1800))

        let page = try #require(rig.http.requests.first)
        #expect(page.url?.absoluteString == "https://www.youtube.com/tv")
        #expect(page.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version")
        #expect(page.value(forHTTPHeaderField: "Authorization") == nil)
        let script = rig.http.requests[1]
        #expect(script.url?.absoluteString == "https://www.youtube.com/s/tv/m=base")

        let request = try #require(rig.http.requests.last)
        #expect(request.url?.absoluteString == "https://www.youtube.com/o/oauth2/device/code")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(rig.http.bodyJSON(of: request))
        #expect(body["client_id"]?.string == "tvsynthetic_client_1")
        #expect(body["scope"]?.string == "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content")
        #expect(body["device_model"]?.string == "ytlr::")
        let deviceID = try #require(body["device_id"]?.string)
        #expect(!deviceID.isEmpty)
        #expect(rig.defaults.string(forKey: "noslop.tvDeviceID") == deviceID)
    }

    @Test func theDeviceIDIsKeptPerInstall() async throws {
        let rig = Rig()
        rig.queueClientValues()
        rig.queueDeviceCode()
        _ = try await rig.service.beginSignIn()
        _ = try await rig.service.beginSignIn()
        let ids = rig.http.requests
            .filter { $0.url?.absoluteString.contains("device/code") == true }
            .compactMap { rig.http.bodyJSON(of: $0)?["device_id"]?.string }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 1)
    }

    @Test func pollingHonoursIntervalAndSlowDown() async throws {
        let rig = Rig()
        rig.queueClientValues()
        rig.queueDeviceCode(interval: 3)
        rig.queueToken(#"{"error":"authorization_pending"}"#, status: 428)
        rig.queueToken(#"{"error":"slow_down"}"#, status: 400)
        rig.queueToken(#"{"error":"authorization_pending"}"#, status: 428)
        rig.queueToken(success)
        let prompt = try await rig.service.beginSignIn()
        let account = try await rig.service.completeSignIn(prompt)

        #expect(rig.clock.sleeps == [5, 10, 10])
        #expect(rig.tokenRequests.count == 4)
        #expect(account.connectedAt == rig.clock.now)
        #expect(try rig.store.load()?.refreshToken == "tvsynthetic_refresh_1")
    }

    @Test func theErrorFieldDecidesWhateverTheStatus() async throws {
        let rig = Rig()
        rig.queueClientValues()
        rig.queueDeviceCode()
        // Pending under a 200, then a success under a 400: the status is not trusted either way.
        rig.queueToken(#"{"error":"authorization_pending"}"#, status: 200)
        rig.queueToken(success, status: 400)
        let prompt = try await rig.service.beginSignIn()
        _ = try await rig.service.completeSignIn(prompt)
        #expect(rig.clock.sleeps == [5])
    }

    @Test func aDeclinedOrExpiredCodeStops() async throws {
        for (reply, message) in [
            (#"{"error":"access_denied"}"#, "The sign-in was declined."),
            (#"{"error":"expired_token"}"#, "The code expired. Start again."),
        ] {
            let rig = Rig()
            rig.queueClientValues()
            rig.queueDeviceCode()
            rig.queueToken(reply, status: 400)
            let prompt = try await rig.service.beginSignIn()
            await #expect(throws: NoSlopError.oauth(message)) { _ = try await rig.service.completeSignIn(prompt) }
            #expect(try rig.store.load() == nil)
        }
    }

    @Test func pollingStopsAtTheExpiryTime() async throws {
        let rig = Rig()
        rig.queueClientValues()
        rig.queueDeviceCode(interval: 5, expiresIn: 12)
        rig.queueToken(#"{"error":"authorization_pending"}"#, status: 428)
        let prompt = try await rig.service.beginSignIn()
        await #expect(throws: NoSlopError.oauth("The code expired. Start again.")) { _ = try await rig.service.completeSignIn(prompt) }
        // Polls at 0, 5 and 10 s; at 15 s the 12 s are over.
        #expect(rig.tokenRequests.count == 3)
    }

    @Test func cancellationStopsThePolling() async throws {
        let rig = Rig()
        rig.queueClientValues()
        rig.queueDeviceCode()
        rig.queueToken(#"{"error":"authorization_pending"}"#, status: 428)
        let prompt = try await rig.service.beginSignIn()
        let service = rig.service
        let task = Task { try await service.completeSignIn(prompt) }
        task.cancel()
        await #expect(throws: NoSlopError.cancelled) { _ = try await task.value }
    }

    @Test func aCancelDuringTheTokenRequestKeepsTheCodeForARestart() async throws {
        let rig = Rig()
        rig.queueClientValues()
        rig.queueDeviceCode()
        rig.http.enqueueError("oauth2/token", NoSlopError.cancelled)
        rig.queueToken(success)
        let prompt = try await rig.service.beginSignIn()
        await #expect(throws: NoSlopError.cancelled) { _ = try await rig.service.completeSignIn(prompt) }
        // The restarted poll on the same prompt still has its device code and finishes the sign-in.
        _ = try await rig.service.completeSignIn(prompt)
        #expect(try rig.store.load()?.refreshToken == "tvsynthetic_refresh_1")
    }

    @Test func aRefreshKeepsANewRefreshToken() async throws {
        let rig = Rig(credentials: stored(expiresIn: 100))
        rig.queueToken("""
        {"access_token":"tvsynthetic_access_2","refresh_token":"tvsynthetic_refresh_2","expires_in":3599}
        """)
        let token = try await rig.service.accessToken()
        #expect(token == "tvsynthetic_access_2")
        let saved = try #require(try rig.store.load())
        #expect(saved.refreshToken == "tvsynthetic_refresh_2")
        #expect(saved.expiresAt == rig.clock.now.addingTimeInterval(3599))
        #expect(saved.accountName == "Synthetic Name")
        #expect(saved.clientID == "tvsynthetic_client_1")

        let body = try #require(rig.firstTokenBody)
        #expect(body["grant_type"]?.string == "refresh_token")
        #expect(body["refresh_token"]?.string == "tvsynthetic_refresh_old")
        #expect(body["client_secret"]?.string == "tvsynthetic_secret_1")
    }

    @Test func aRefreshWithoutANewRefreshTokenKeepsTheOldOne() async throws {
        let rig = Rig(credentials: stored(expiresIn: 100))
        rig.queueToken(#"{"access_token":"tvsynthetic_access_3","expires_in":3599}"#)
        _ = try await rig.service.accessToken()
        #expect(try rig.store.load()?.refreshToken == "tvsynthetic_refresh_old")
    }

    @Test func aTokenWithTimeLeftIsNotRefreshed() async throws {
        let rig = Rig(credentials: stored(expiresIn: 301))
        #expect(try await rig.service.accessToken() == "tvsynthetic_access_old")
        #expect(rig.http.requests.isEmpty)
        rig.clock.advance(2)
        rig.queueToken(#"{"access_token":"tvsynthetic_access_4","expires_in":3599}"#)
        #expect(try await rig.service.accessToken() == "tvsynthetic_access_4")
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let rig = Rig(credentials: stored(expiresIn: 50))
        rig.queueToken(#"{"access_token":"tvsynthetic_access_5","expires_in":3599}"#)
        let service = rig.service
        async let first = service.accessToken()
        async let second = service.accessToken()
        let (a, b) = try await (first, second)
        #expect(a == "tvsynthetic_access_5")
        #expect(b == "tvsynthetic_access_5")
        #expect(rig.tokenRequests.count == 1)
    }

    @Test func aRefreshAfterUnauthorizedRefreshesEvenWithTimeLeft() async throws {
        let rig = Rig(credentials: stored(expiresIn: 3000))
        rig.queueToken(#"{"access_token":"tvsynthetic_access_6","expires_in":3599}"#)
        #expect(try await rig.service.refreshAfterUnauthorized() == "tvsynthetic_access_6")
        #expect(rig.tokenRequests.count == 1)
    }

    @Test func anEndedGrantClearsTheStoreAndSaysNotConnected() async throws {
        for error in ["invalid_grant", "invalid_client", "unauthorized_client"] {
            let rig = Rig(credentials: stored(expiresIn: 10))
            rig.queueToken("{\"error\":\"\(error)\"}", status: 400)
            await #expect(throws: NoSlopError.recommendationsNotConnected) { _ = try await rig.service.accessToken() }
            #expect(try rig.store.load() == nil)
            #expect(await rig.service.currentAccount() == nil)
            // With nothing stored, asking again does not touch the network.
            let before = rig.http.requests.count
            await #expect(throws: NoSlopError.recommendationsNotConnected) { _ = try await rig.service.accessToken() }
            #expect(rig.http.requests.count == before)
        }
    }

    @Test func aNetworkErrorNeverClearsTheStore() async throws {
        let rig = Rig(credentials: stored(expiresIn: 10))
        rig.http.enqueueError("oauth2/token", NoSlopError.network("offline"))
        await #expect(throws: NoSlopError.network("offline")) { _ = try await rig.service.accessToken() }
        #expect(try rig.store.load() != nil)

        // A server error or an unknown error name does not end the grant either.
        let rig2 = Rig(credentials: stored(expiresIn: 10))
        rig2.queueToken("", status: 503)
        await #expect(throws: NoSlopError.http(status: 503)) { _ = try await rig2.service.accessToken() }
        #expect(try rig2.store.load() != nil)
    }

    @Test func theAccountNameComesFromAccountsListWhenItAnswers() async throws {
        let rig = Rig()
        rig.queueClientValues()
        rig.queueDeviceCode()
        rig.queueToken(success)
        rig.http.enqueue("youtubei/v1/account/accounts_list", body: Data("""
        {"contents":[{"accountSectionListRenderer":{"contents":[{"accountItemSectionRenderer":{"contents":[{"accountItem":{"accountName":{"simpleText":"Synthetic Person"},"isSelected":true}}]}}]}}]}
        """.utf8))
        let prompt = try await rig.service.beginSignIn()
        let account = try await rig.service.completeSignIn(prompt)
        #expect(account.name == "Synthetic Person")
        #expect(try rig.store.load()?.accountName == "Synthetic Person")
        let request = try #require(rig.http.requests.last)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tvsynthetic_access_1")
        let context = try #require(rig.http.bodyJSON(of: request)?["context"]?["client"])
        #expect(context["clientName"]?.string == "TVHTML5")
        #expect(await rig.service.currentAccount()?.name == "Synthetic Person")
    }

    @Test func aMissingAccountNameIsNotAnError() async throws {
        let rig = Rig()
        rig.queueClientValues()
        rig.queueDeviceCode()
        rig.queueToken(success)
        let prompt = try await rig.service.beginSignIn()
        let account = try await rig.service.completeSignIn(prompt)
        #expect(account.name == nil)
        #expect(try rig.store.load() != nil)
    }

    @Test func secondsLeftCountsDownToTheExpiry() async throws {
        let rig = Rig(credentials: stored(expiresIn: 1000))
        #expect(await rig.service.secondsLeft() == 1000)
        rig.clock.advance(400)
        #expect(await rig.service.secondsLeft() == 600)
        let empty = Rig()
        #expect(await empty.service.secondsLeft() == nil)
    }

    @Test func missingClientValuesStopTheSignInWithAPlainSentence() async throws {
        let rig = Rig()
        rig.queueClientValues(script: "var nothing=1;")
        await #expect(throws: NoSlopError.oauth("The sign-in couldn't start. Try again later.")) { _ = try await rig.service.beginSignIn() }
    }

    @Test func aRefreshInFlightDuringDisconnectDoesNotBringTheCredentialsBack() async throws {
        let http = GatedHTTP()
        let store = InMemoryTVTokenStore()
        try store.save(stored(expiresIn: 100))
        let suite = "tvsynthetic.\(UUID().uuidString)"
        let service = TVAuthService(
            http: http, store: store, defaults: UserDefaults(suiteName: suite)!,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, sleep: { _ in }
        )
        let refresh = Task { try await service.accessToken() }
        await http.waitForTokenRequest()
        _ = await service.disconnect()
        #expect(try store.load() == nil)
        http.release()
        await #expect(throws: (any Error).self) { _ = try await refresh.value }
        #expect(try store.load() == nil)
        #expect(await service.currentAccount() == nil)
    }

    @Test func disconnectClearsTheStoreEvenWhenRevokeFails() async throws {
        let rig = Rig(credentials: stored(expiresIn: 3000))
        rig.http.enqueue("oauth2.googleapis.com/revoke", status: 400, body: Data("{}".utf8))
        rig.http.enqueueError("youtube.com/o/oauth2/revoke", NoSlopError.network("offline"))
        let revoked = await rig.service.disconnect()
        #expect(revoked == false)
        #expect(try rig.store.load() == nil)
        #expect(await rig.service.currentAccount() == nil)
        #expect(rig.http.requests.count == 2)
    }

    @Test func disconnectTriesTheFormThenTheJSONRevokeAndStopsAtTheFirst200() async throws {
        let rig = Rig(credentials: stored(expiresIn: 3000))
        rig.http.enqueue("oauth2.googleapis.com/revoke", status: 400, body: Data())
        rig.http.enqueue("youtube.com/o/oauth2/revoke", body: Data())
        #expect(await rig.service.disconnect() == true)
        let form = rig.http.requests[0]
        #expect(form.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(form.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(String(data: try #require(form.httpBody), encoding: .utf8) == "token=tvsynthetic_refresh_old")
        let json = rig.http.requests[1]
        #expect(json.url?.absoluteString == "https://www.youtube.com/o/oauth2/revoke")
        #expect(json.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(rig.http.bodyJSON(of: json)?["token"]?.string == "tvsynthetic_refresh_old")

        let first = Rig(credentials: stored(expiresIn: 3000))
        first.http.enqueue("oauth2.googleapis.com/revoke", body: Data())
        #expect(await first.service.disconnect() == true)
        #expect(first.http.requests.count == 1)
    }

    @Test func disconnectWithNothingStoredIsQuietAndFalse() async {
        let rig = Rig()
        #expect(await rig.service.disconnect() == false)
        #expect(rig.http.requests.isEmpty)
    }

    @Test func currentAccountReadsTheStoreWithoutTheNetwork() async throws {
        let rig = Rig(credentials: stored(expiresIn: 3000))
        let account = await rig.service.currentAccount()
        #expect(account?.name == "Synthetic Name")
        #expect(account?.connectedAt == rig.clock.now.addingTimeInterval(-86_400))
        #expect(rig.http.requests.isEmpty)
    }

    @Test func credentialsDescriptionShowsNoSecrets() {
        let credentials = stored(expiresIn: 100)
        for text in [credentials.description, String(describing: credentials), String(reflecting: credentials), "\(credentials)"] {
            for secret in ["tvsynthetic_access_old", "tvsynthetic_refresh_old", "tvsynthetic_secret_1", "tvsynthetic_client_1"] {
                #expect(!text.contains(secret))
            }
        }
    }
}
