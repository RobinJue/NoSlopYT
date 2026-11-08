import Foundation
import Testing
@testable import NoSlopKit

/// A token provider the tests can read back: hands out "tvsynthetic_token_1" first and "tvsynthetic_token_2" after a refresh.
private final class FakeTokens: TVTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current = "tvsynthetic_token_1"
    private var refreshes = 0

    var refreshCount: Int { lock.withLock { refreshes } }

    func accessToken() async throws -> String {
        lock.withLock { current }
    }

    func refreshAfterUnauthorized() async throws -> String {
        lock.withLock {
            refreshes += 1
            current = "tvsynthetic_token_\(refreshes + 1)"
            return current
        }
    }
}

private func ok(_ text: String = "{\"ok\":true}") -> Data { Data(text.utf8) }

@Suite struct TVClientTests {
    @Test func tvRequestsCarryTheBearerAndTheTVHeaders() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: ok())
        let client = TVClient(http: http, tokens: FakeTokens())
        let reply = try await client.post("browse", body: ["browseId": "FEwhat_to_watch"], visitorData: "tvsynthetic_visitor")

        #expect(reply?["ok"] == true)
        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.youtube.com/tv")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tvsynthetic_token_1")
        #expect(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == "tvsynthetic_visitor")
        #expect(request.url?.absoluteString.contains("key=") == false)
        #expect(http.bodyJSON(of: request)?["browseId"]?.string == "FEwhat_to_watch")
    }

    @Test func theLegacyProfileAndTheOtherHostAreUsed() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei.googleapis.com", body: ok())
        let client = TVClient(http: http, tokens: FakeTokens())
        _ = try await client.post("browse", body: [:], profile: .legacy, host: "youtubei.googleapis.com")
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://youtubei.googleapis.com/youtubei/v1/browse?prettyPrint=false")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0 (DirectFB; Linux x86_64) Cobalt/4.13031-qa (unlike Gecko) Starboard/1")
        #expect(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == nil)
    }

    @Test func aHostOutsideTheAllowListIsRefused() async {
        let http = MockHTTPClient()
        http.enqueue("example.com", body: ok())
        let client = TVClient(http: http, tokens: FakeTokens())
        await #expect(throws: NoSlopError.self) {
            _ = try await client.post("browse", body: [:], host: "example.com")
        }
        await #expect(throws: NoSlopError.self) {
            _ = try await client.get(URL(string: "https://example.com/ping")!, profile: .tv, authorized: true)
        }
        await #expect(throws: NoSlopError.self) {
            _ = try await client.get(URL(string: "http://www.youtube.com/ping")!, profile: .tv, authorized: false)
        }
        #expect(http.requests.isEmpty)
    }

    @Test func anEmptyBodyIsNotAnError() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/a", body: Data())
        http.enqueue("youtubei/v1/b", status: 204, body: Data())
        let client = TVClient(http: http, tokens: FakeTokens())
        #expect(try await client.post("a", body: [:]) == nil)
        #expect(try await client.post("b", body: [:]) == nil)
    }

    @Test func a401RefreshesOnceThenFails() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", status: 401, body: Data())
        http.enqueue("youtubei/v1/browse", body: ok())
        let tokens = FakeTokens()
        let client = TVClient(http: http, tokens: tokens)
        let reply = try await client.post("browse", body: [:])
        #expect(reply?["ok"] == true)
        #expect(http.requests.count == 2)
        #expect(http.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer tvsynthetic_token_1")
        #expect(http.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tvsynthetic_token_2")
        #expect(tokens.refreshCount == 1)

        let failing = MockHTTPClient()
        failing.enqueue("youtubei/v1/browse", status: 401, body: Data())
        let secondTokens = FakeTokens()
        let failingClient = TVClient(http: failing, tokens: secondTokens)
        await #expect(throws: NoSlopError.recommendationsNotConnected) {
            _ = try await failingClient.post("browse", body: [:])
        }
        #expect(failing.requests.count == 2)
        #expect(secondTokens.refreshCount == 1)
    }

    @Test func otherFailuresThrowHTTPWithoutARefresh() async {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", status: 500, body: Data())
        let tokens = FakeTokens()
        let client = TVClient(http: http, tokens: tokens)
        await #expect(throws: NoSlopError.http(status: 500)) {
            _ = try await client.post("browse", body: [:])
        }
        #expect(tokens.refreshCount == 0)
        #expect(http.requests.count == 1)
    }

    @Test func tvRequestsUseOnlyTheTVToken() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: ok())
        http.enqueue("/api/stats/playback", body: Data())
        let client = TVClient(http: http, tokens: FakeTokens())
        _ = try await client.post("browse", body: [:])
        let status = try await client.get(URL(string: "https://www.youtube.com/api/stats/playback?x=1")!, profile: .tv, authorized: true)
        let anonymous = try await client.get(URL(string: "https://www.youtube.com/api/stats/playback?x=2")!, profile: .tv, authorized: false)
        #expect(status == 200 && anonymous == 200)
        for request in http.requests.prefix(2) {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tvsynthetic_token_1")
        }
        let unauthorized = try #require(http.requests.last)
        #expect(unauthorized.httpMethod == "GET")
        #expect(unauthorized.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(unauthorized.value(forHTTPHeaderField: "User-Agent") == "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version")
        // No request ever carries a Google Data API token or a cookie.
        for request in http.requests {
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == nil)
        }
    }

    @Test func aGetReturnsTheStatusOnly() async throws {
        let http = MockHTTPClient()
        http.enqueue("/api/stats/watchtime", status: 404, body: Data("nope".utf8))
        let client = TVClient(http: http, tokens: FakeTokens())
        let status = try await client.get(URL(string: "https://www.youtube.com/api/stats/watchtime")!, profile: .legacy, authorized: true)
        #expect(status == 404)
    }

    @Test func theContextFollowsTheProbesFullVariant() throws {
        let context = TVClientConfig.context(.tv, visitorData: "tvsynthetic_visitor", language: "de", region: "DE")
        let client = try #require(context["client"])
        #expect(client["clientName"] == "TVHTML5")
        #expect(client["clientVersion"] == "7.20260901.15.00")
        #expect(client["clientScreen"] == "WATCH")
        #expect(client["userAgent"] == "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version")
        #expect(client["hl"] == "de")
        #expect(client["gl"] == "DE")
        #expect(client["visitorData"] == "tvsynthetic_visitor")
        #expect(client["tvAppInfo"]?["appQuality"] == "TV_APP_QUALITY_FULL_ANIMATION")
        #expect(client["tvAppInfo"]?["zylonLeftNav"] == true)

        let legacy = TVClientConfig.context(.legacy, visitorData: nil, language: "en", region: "US")
        #expect(legacy["client"]?["clientVersion"] == "5.20260901")
        #expect(legacy["client"]?["visitorData"] == nil)
    }

    @Test func theConstantsMatchThePlan() {
        #expect(TVClientConfig.allowedHosts == ["www.youtube.com", "youtubei.googleapis.com", "oauth2.googleapis.com"])
        #expect(TVClientConfig.referer == "https://www.youtube.com/tv")
        #expect(TVClientConfig.homeRecipes.map(\.browseID) == ["FEwhat_to_watch", "default", "FEwhat_to_watch"])
        #expect(TVClientConfig.homeRecipes.map(\.host) == ["www.youtube.com", "www.youtube.com", "youtubei.googleapis.com"])
        #expect(NoSlopError.recommendationsNotConnected.errorDescription == "YouTube recommendations aren't connected.")
    }
}
