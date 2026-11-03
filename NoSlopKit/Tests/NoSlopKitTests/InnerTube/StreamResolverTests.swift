import Foundation
import Testing
@testable import NoSlopKit

// MARK: - Helpers

private func token(_ n: Int) -> String {
    "CgSyntheticVisitorData" + String(format: "%04d", n)
}

private func swJsDataBody(visitorData: String) throws -> Data {
    var inner = [JSON](repeating: .null, count: 14)
    inner[13] = .string(visitorData)
    let document = JSON.array([.array([.string("yt.sw.adr"), .null, .array([.array([.array(inner)])])])])
    return Data(")]}'\n\n".utf8) + (try document.data())
}

private let botCheckBody = Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm you’re not a bot"}}"#.utf8)

private func makeResolver(_ http: MockHTTPClient) -> InnerTubeStreamResolver {
    let client = InnerTubeClient(http: http, config: InnerTubeConfig(hl: "en", gl: "US"), visitorStore: InMemoryVisitorDataStore())
    return InnerTubeStreamResolver(client: client)
}

private func playerRequests(_ http: MockHTTPClient) -> [URLRequest] {
    http.requests.filter { $0.url?.absoluteString.contains("youtubei/v1/player") == true }
}

private func visitorRequests(_ http: MockHTTPClient) -> [URLRequest] {
    http.requests.filter { $0.url?.absoluteString.contains("sw.js_data") == true }
}

@Suite struct StreamResolverTests {
    // MARK: From the plan

    @Test func retriesOnceWithFreshVisitorDataOnBotCheck() async throws {
        // sw.js_data(vd1) -> player(bot) -> sw.js_data(vd2) -> player(OK)
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: botCheckBody)
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(2)))
        http.enqueue("youtubei/v1/player", body: try Fixture.data("player_visionos_bigbuckbunny.json"))

        let info = try await makeResolver(http).streamInfo(videoID: "aqz-KE-bpKQ")

        #expect(info.videoID == "aqz-KE-bpKQ")
        #expect(info.hlsURL != nil)
        let players = playerRequests(http)
        try #require(players.count == 2)
        #expect(players[0].value(forHTTPHeaderField: "X-Goog-Visitor-Id") == token(1))
        #expect(players[1].value(forHTTPHeaderField: "X-Goog-Visitor-Id") == token(2))
        #expect(visitorRequests(http).count == 2)
        // The retry carries the new token in the body too.
        let retryBody = try #require(http.bodyJSON(of: players[1]))
        #expect(retryBody["context"]?["client"]?["visitorData"]?.string == token(2))
        #expect(retryBody["videoId"]?.string == "aqz-KE-bpKQ")
    }

    @Test func secondBotCheckThrowsBotCheck() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: botCheckBody)

        let resolver = makeResolver(http)
        await #expect(throws: NoSlopError.botCheck) {
            _ = try await resolver.streamInfo(videoID: "aqz-KE-bpKQ")
        }
        #expect(playerRequests(http).count == 2)
    }

    // MARK: Request and result

    @Test func playerRequestAsksForTheHLSPlaybackPath() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: try Fixture.data("player_visionos_bigbuckbunny.json"))
        _ = try await makeResolver(http).streamInfo(videoID: "aqz-KE-bpKQ")

        let request = try #require(playerRequests(http).first)
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "101")
        let body = try #require(http.bodyJSON(of: request))
        #expect(body["videoId"]?.string == "aqz-KE-bpKQ")
        #expect(body["contentCheckOk"]?.bool == true)
        #expect(body["racyCheckOk"]?.bool == true)
        #expect(body["playbackContext"]?["contentPlaybackContext"]?["html5Preference"]?.string == "HTML5_PREF_WANTS")
        #expect(body["context"]?["client"]?["clientName"]?.string == "VISIONOS")
    }

    @Test func returnsTheParsedStreamInfo() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: try Fixture.data("player_visionos_rickroll.json"))
        let info = try await makeResolver(http).streamInfo(videoID: "dQw4w9WgXcQ")
        #expect(info.videoID == "dQw4w9WgXcQ")
        #expect(info.captions.count == 6)
        #expect(info.hlsURL != nil)
        #expect(playerRequests(http).count == 1)
        #expect(visitorRequests(http).count == 1)
    }

    @Test func expiryIsRelativeToTheInjectedClock() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: try Fixture.data("player_visionos_bigbuckbunny.json"))
        let client = InnerTubeClient(http: http, config: InnerTubeConfig(hl: "en", gl: "US"), visitorStore: InMemoryVisitorDataStore())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let resolver = InnerTubeStreamResolver(client: client, now: { t0 })
        let info = try await resolver.streamInfo(videoID: "aqz-KE-bpKQ")
        #expect(info.expiresAt == t0.addingTimeInterval(21_540))
    }

    @Test func everyCallResolvesFresh() async throws {
        // Playback recovery relies on this: a second call must hit the network again, never a cached StreamInfo.
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: try Fixture.data("player_visionos_bigbuckbunny.json"))
        let resolver = makeResolver(http)
        _ = try await resolver.streamInfo(videoID: "aqz-KE-bpKQ")
        _ = try await resolver.streamInfo(videoID: "aqz-KE-bpKQ")
        #expect(playerRequests(http).count == 2)
        // …while the visitorData is reused.
        #expect(visitorRequests(http).count == 1)
    }

    // MARK: What is not retried

    @Test func unplayableVideosAreNotRetried() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: Data(#"{"playabilityStatus":{"status":"LOGIN_REQUIRED","reason":"Sign in to confirm your age"}}"#.utf8))
        let resolver = makeResolver(http)
        await #expect(throws: NoSlopError.unplayable(reason: "Sign in to confirm your age")) {
            _ = try await resolver.streamInfo(videoID: "x")
        }
        #expect(playerRequests(http).count == 1)
        #expect(visitorRequests(http).count == 1)
    }

    @Test func httpErrorsAreNotRetried() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", status: 500, body: Data())
        let resolver = makeResolver(http)
        await #expect(throws: NoSlopError.http(status: 500)) {
            _ = try await resolver.streamInfo(videoID: "x")
        }
        #expect(playerRequests(http).count == 1)
    }

    @Test func networkErrorsAreNotRetried() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueueError("youtubei/v1/player", NoSlopError.network("offline"))
        let resolver = makeResolver(http)
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await resolver.streamInfo(videoID: "x")
        }
        #expect(playerRequests(http).count == 1)
    }

    @Test func aFailingVisitorRefreshSurfacesItsError() async throws {
        // The bot check leads to a refresh; when that fails there is no second player request.
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: botCheckBody)
        http.enqueueError("sw.js_data", NoSlopError.network("offline"))
        let resolver = makeResolver(http)
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await resolver.streamInfo(videoID: "x")
        }
        #expect(playerRequests(http).count == 1)
    }

    @Test func aRecoveredTokenStaysInUse() async throws {
        // After the retry succeeded with vd2, later videos use vd2 without fetching again.
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: botCheckBody)
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(2)))
        http.enqueue("youtubei/v1/player", body: try Fixture.data("player_visionos_bigbuckbunny.json"))
        let resolver = makeResolver(http)
        _ = try await resolver.streamInfo(videoID: "aqz-KE-bpKQ")
        _ = try await resolver.streamInfo(videoID: "aqz-KE-bpKQ")
        let players = playerRequests(http)
        try #require(players.count == 3)
        #expect(players[2].value(forHTTPHeaderField: "X-Goog-Visitor-Id") == token(2))
        #expect(visitorRequests(http).count == 2)
    }
}
