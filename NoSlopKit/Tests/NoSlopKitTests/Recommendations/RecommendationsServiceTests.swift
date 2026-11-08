import Foundation
import Testing
@testable import NoSlopKit

private struct FakeTVTokens: TVTokenProviding {
    func accessToken() async throws -> String { "tvsynthetic_token" }
    func refreshAfterUnauthorized() async throws -> String { "tvsynthetic_token_2" }
}

private func data(_ json: JSON) throws -> Data { try json.data() }

private func withVisitor(_ json: JSON, _ visitor: String) -> JSON {
    guard case .object(var object) = json else { return json }
    var context = object["responseContext"]?.object ?? [:]
    context["visitorData"] = .string(visitor)
    object["responseContext"] = .object(context)
    return .object(object)
}

private func freshSuite() -> String { "tvsynthetic.\(UUID().uuidString)" }

private func defaults(_ suite: String) -> UserDefaults { UserDefaults(suiteName: suite)! }

private func makeService(_ http: MockHTTPClient, suite: String) -> RecommendationsService {
    RecommendationsService(client: TVClient(http: http, tokens: FakeTVTokens()), language: "en", region: "US", defaults: defaults(suite))
}

/// Holds every reply until `release()`; `started()` returns once a request is waiting.
private final class GatedHTTP: HTTPClient, @unchecked Sendable {
    private let inner: MockHTTPClient
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false
    init(_ inner: MockHTTPClient) { self.inner = inner }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = lock.withLock { () -> Bool in
                if open { return true }
                waiting.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
        return try await inner.send(request)
    }

    func started() async {
        while lock.withLock({ waiting.isEmpty }) { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    func release() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiting = [] }
            return waiting
        }
        all.forEach { $0.resume() }
    }
}

@Suite struct RecommendationsServiceTests {
    @Test func theLadderMovesOnFromASignedOutReply() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_signed_out.json")))
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_mixed.json")))
        let suite = freshSuite()
        let service = makeService(http, suite: suite)

        let page = try await service.homePage(continuation: nil)
        #expect(page.loggedIn == true)
        #expect(page.videos.map(\.id) == ["vidLIVE0001", "vidMEMBER01", "vidPLAIN001"])
        #expect(page.report.recipe == "default@www.youtube.com")
        #expect(page.report.usedYouTube)
        let browseIDs = http.requests.compactMap { http.bodyJSON(of: $0)?["browseId"]?.string }
        #expect(browseIDs == ["FEwhat_to_watch", "default"])

        // The working recipe is remembered, also by a new service.
        #expect(defaults(suite).string(forKey: "noslop.tvHomeRecipe") == "default|www.youtube.com")
        let http2 = MockHTTPClient()
        http2.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_mixed.json")))
        let second = makeService(http2, suite: suite)
        _ = try await second.homePage(continuation: nil)
        #expect(http2.bodyJSON(of: try #require(http2.requests.first))?["browseId"]?.string == "default")
    }

    @Test func aRememberedRecipeIsTriedFirst() async throws {
        let suite = freshSuite()
        defaults(suite).set("FEwhat_to_watch|youtubei.googleapis.com", forKey: "noslop.tvHomeRecipe")
        let http = MockHTTPClient()
        http.enqueue("youtubei.googleapis.com/youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_mixed.json")))
        let service = makeService(http, suite: suite)
        _ = try await service.homePage(continuation: nil)
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.url?.host == "youtubei.googleapis.com")
    }

    @Test func aGarbledRememberedRecipeIsIgnored() async throws {
        let suite = freshSuite()
        defaults(suite).set("evil|example.com", forKey: "noslop.tvHomeRecipe")
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_mixed.json")))
        let service = makeService(http, suite: suite)
        _ = try await service.homePage(continuation: nil)
        #expect(http.bodyJSON(of: try #require(http.requests.first))?["browseId"]?.string == "FEwhat_to_watch")
    }

    @Test func continuationsUseTheFirstRepliesVisitorData() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(withVisitor(try Fixture.json("tvsynthetic_home_mixed.json"), "tvsynthetic_visitor")))
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_section_cont.json")))
        let service = makeService(http, suite: freshSuite())

        let first = try await service.homePage(continuation: nil)
        let token = try #require(first.continuation)
        #expect(token == "SECTIONCONT-1")
        _ = try await service.homePage(continuation: token)

        let requests = http.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "X-Goog-Visitor-Id") == nil)
        #expect(http.bodyJSON(of: requests[0])?["context"]?["client"]?["visitorData"] == nil)
        #expect(requests[1].value(forHTTPHeaderField: "X-Goog-Visitor-Id") == "tvsynthetic_visitor")
        let body = try #require(http.bodyJSON(of: requests[1]))
        #expect(body["context"]?["client"]?["visitorData"]?.string == "tvsynthetic_visitor")
        #expect(body["continuation"]?.string == "SECTIONCONT-1")
        #expect(body["browseId"] == nil)
        #expect(requests[1].url?.host == "www.youtube.com")
    }

    @Test func everyRecipeFailingThrowsAndNothingIsRemembered() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", status: 500, body: Data("{}".utf8))
        let suite = freshSuite()
        let service = makeService(http, suite: suite)
        await #expect(throws: NoSlopError.self) { _ = try await service.homePage(continuation: nil) }
        #expect(http.requests.count == 3)
        #expect(defaults(suite).string(forKey: "noslop.tvHomeRecipe") == nil)
        let report = await service.diagnostics().lastHome
        #expect(report?.status == 500)
        #expect(report?.usedYouTube == false)
    }

    @Test func aSignedOutAnswerEverywhereIsReturnedForTheFallback() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_signed_out.json")))
        let service = makeService(http, suite: freshSuite())
        let page = try await service.homePage(continuation: nil)
        #expect(page.loggedIn == false)
        #expect(page.videos.isEmpty)
        #expect(!page.report.usedYouTube)
        #expect(http.requests.count == 3)
    }

    @Test func notConnectedStopsTheLadderAtOnce() async throws {
        struct Disconnected: TVTokenProviding {
            func accessToken() async throws -> String { throw NoSlopError.recommendationsNotConnected }
            func refreshAfterUnauthorized() async throws -> String { throw NoSlopError.recommendationsNotConnected }
        }
        let http = MockHTTPClient()
        let service = RecommendationsService(client: TVClient(http: http, tokens: Disconnected()), language: "en", region: "US", defaults: defaults(freshSuite()))
        await #expect(throws: NoSlopError.recommendationsNotConnected) { _ = try await service.homePage(continuation: nil) }
        #expect(http.requests.isEmpty)
    }

    @Test func cardHandlesAreKeptForTheVideosOfTheFirstPage() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_mixed.json")))
        let service = makeService(http, suite: freshSuite())
        let page = try await service.homePage(continuation: nil)
        let parsed = TVHomeParser.parse(try Fixture.json("tvsynthetic_home_mixed.json"))
        #expect(page.cardIDs == Set(parsed.handles.keys).intersection(page.videos.map(\.id)))
        for id in page.cardIDs { #expect(await service.hasHandle(for: id)) }
    }

    @Test func diagnosticsSampleIsScrubbed() async throws {
        var reply = withVisitor(try Fixture.json("tvsynthetic_home_mixed.json"), "tvsynthetic_visitor")
        guard case .object(var object) = reply else { return }
        object["leak"] = "Bearer ya29.tvsynthetic_leak from 10.9.8.7"
        reply = .object(object)
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(reply))
        let service = makeService(http, suite: freshSuite())
        _ = try await service.homePage(continuation: nil)

        let sample = await service.diagnosticsSample()
        let text = String(decoding: try sample.data(), as: UTF8.self)
        #expect(sample["recentHomeReplies"]?.array?.count == 1)
        #expect(TVScrubber.leaks(text).isEmpty)
        #expect(!text.contains("tvsynthetic_visitor"))
        #expect(!text.contains("tvsynthetic_leak"))
        #expect(!text.contains("SECTIONCONT-1"))
        #expect(!text.contains("Plain video"))
    }

    @Test func onlyTheLastThreeRepliesAreKept() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_mixed.json")))
        let service = makeService(http, suite: freshSuite())
        for _ in 0..<5 { _ = try await service.homePage(continuation: nil) }
        #expect(await service.diagnosticsSample()["recentHomeReplies"]?.array?.count == 3)
    }

    @Test func clearAccountDataForgetsHandlesAndCache() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_mixed.json")))
        let service = makeService(http, suite: freshSuite())
        let page = try await service.homePage(continuation: nil)
        let id = try #require(page.cardIDs.first)
        #expect(await service.hasHandle(for: id))

        await service.clearAccountData()
        #expect(await !service.hasHandle(for: id))
        #expect(await service.diagnostics().lastHome == nil)
        #expect(await service.diagnosticsSample()["recentHomeReplies"]?.array?.isEmpty == true)
        // The old continuation no longer carries the old visitor.
        let before = http.requests.count
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_section_cont.json")))
        _ = try await service.homePage(continuation: "SECTIONCONT-1")
        #expect(http.requests[before].value(forHTTPHeaderField: "X-Goog-Visitor-Id") == nil)
    }

    @Test func aClearDuringAPendingLoadLeavesNothingBehind() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_mixed.json")))
        let gate = GatedHTTP(http)
        let service = RecommendationsService(client: TVClient(http: gate, tokens: FakeTVTokens()), language: "en", region: "US", defaults: defaults(freshSuite()))
        let load = Task { try await service.homePage(continuation: nil) }
        await gate.started()
        await service.clearAccountData()
        gate.release()
        let page = try await load.value
        #expect(!page.videos.isEmpty)
        let id = try #require(page.cardIDs.first)
        #expect(await !service.hasHandle(for: id))
        #expect(await service.diagnostics().lastHome == nil)
        #expect(await service.diagnosticsSample()["recentHomeReplies"]?.array?.isEmpty == true)
    }

    @Test func nothingSecretReachesTheReport() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei/v1/browse", body: try data(try Fixture.json("tvsynthetic_home_mixed.json")))
        let service = makeService(http, suite: freshSuite())
        _ = try await service.homePage(continuation: nil)
        let report = try #require(await service.diagnostics().lastHome)
        let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!text.contains("SECTIONCONT"))
        #expect(report.status == 200 && report.loggedIn == true && report.videos == 3 && report.shorts == 3)
    }
}
