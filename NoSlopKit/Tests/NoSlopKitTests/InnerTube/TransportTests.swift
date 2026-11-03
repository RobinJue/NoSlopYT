import Foundation
import Testing
@testable import NoSlopKit

// MARK: - Helpers (file-private so they cannot clash with other test files)

/// A clock the tests can move.
private final class TransportTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private let day: TimeInterval = 86_400

/// A visitorData-looking token that the parser accepts ("Cg" + 20 or more URL-safe characters).
private func token(_ n: Int) -> String {
    "CgSyntheticVisitorData" + String(format: "%04d", n)
}

/// A `sw.js_data` response with `visitorData` where YouTube puts it: `[0][2][0][0][13]`.
private func swJsDataBody(visitorData: String) throws -> Data {
    var inner = [JSON](repeating: .null, count: 15)
    inner[0] = "sv"
    inner[1] = "SE"
    inner[11] = "Apple"
    inner[12] = ""
    inner[13] = .string(visitorData)
    inner[14] = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
    let document = JSON.array([.array([.string("yt.sw.adr"), .null, .array([.array([.array(inner)])])])])
    return Data(")]}'\n\n".utf8) + (try document.data())
}

private func makeClient(
    _ http: MockHTTPClient,
    store: any VisitorDataStoring = InMemoryVisitorDataStore(),
    config: InnerTubeConfig = InnerTubeConfig(hl: "en", gl: "US"),
    clock: TransportTestClock? = nil
) -> InnerTubeClient {
    if let clock {
        return InnerTubeClient(http: http, config: config, visitorStore: store, now: { clock.now })
    }
    return InnerTubeClient(http: http, config: config, visitorStore: store)
}

private func requests(_ http: MockHTTPClient, containing fragment: String) -> [URLRequest] {
    http.requests.filter { $0.url?.absoluteString.contains(fragment) == true }
}

// MARK: - Transport

@Suite struct TransportTests {
    // MARK: From the plan

    @Test func visitorDataFromSwJsData() throws {
        let text = String(decoding: try Fixture.data("sw_js_data.txt"), as: UTF8.self)
        let visitorData = SwJsDataParser.visitorData(from: text)
        #expect(visitorData?.hasPrefix("CgtTeW50aGV0aWNWaXNpdG9yRGF0YQ") == true)
        #expect(visitorData?.count == 540)
    }

    @Test func playerRequestShape() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try Fixture.data("sw_js_data.txt"))
        http.enqueue("youtubei/v1/player", body: try Fixture.data("player_visionos_bigbuckbunny.json"))
        let client = makeClient(http)

        let response = try await client.post(endpoint: "player", profile: .visionOS, body: ["videoId": "aqz-KE-bpKQ"])
        #expect(response["videoDetails"]?["videoId"]?.string == "aqz-KE-bpKQ")

        let visitorData = try await client.visitorData()
        let request = try #require(requests(http, containing: "youtubei/v1/player").first)
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "101")
        #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Version") == "1.02")
        #expect(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == visitorData)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.youtube.com")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == ClientProfile.visionOS.userAgent)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(http.bodyJSON(of: request))
        let context = try #require(body["context"]?["client"])
        #expect(context["clientName"]?.string == "VISIONOS")
        #expect(context["clientVersion"]?.string == "1.02")
        #expect(context["deviceMake"]?.string == "Apple")
        #expect(context["deviceModel"]?.string == "RealityDevice17,1")
        #expect(context["osName"]?.string == "visionOS")
        #expect(context["osVersion"]?.string == "26.5.23O471")
        #expect(context["hl"]?.string == "en")
        #expect(context["gl"]?.string == "US")
        #expect(context["visitorData"]?.string == visitorData)
        #expect(body["videoId"]?.string == "aqz-KE-bpKQ")
    }

    @Test func visitorDataCachedSevenDays() async throws {
        let clock = TransportTestClock()
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(2)))
        let client = makeClient(http, clock: clock)

        let first = try await client.visitorData()
        #expect(first == token(1))
        #expect(requests(http, containing: "sw.js_data").count == 1)

        clock.advance(by: 6 * day + 23 * 3_600)
        let withinAWeek = try await client.visitorData()
        #expect(withinAWeek == token(1))
        #expect(requests(http, containing: "sw.js_data").count == 1)

        clock.advance(by: 2 * 3_600)
        let afterAWeek = try await client.visitorData()
        #expect(afterAWeek == token(2))
        #expect(requests(http, containing: "sw.js_data").count == 2)
    }

    @Test func visitorDataFallsBackToVisitorIdEndpoint() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", status: 500, body: Data("boom".utf8))
        http.enqueue("youtubei/v1/visitor_id", body: try Fixture.data("visitor_id.json"))
        let client = makeClient(http)

        let visitorData = try await client.visitorData()
        // The endpoint returns the token percent-encoded ("%3D%3D"); it is stored and sent decoded.
        #expect(visitorData == "CgtTeW50aGV0aWNWaXNpdG9yRGF0YQFixtureValueExtraCgtTeW50aGV0aWNWaXNpdG9yRGF0YQFixtu==")

        let fallback = try #require(requests(http, containing: "youtubei/v1/visitor_id").first)
        #expect(fallback.httpMethod == "POST")
        #expect(fallback.url?.absoluteString == "https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false")
        // It is the call that obtains visitorData, so it cannot carry any.
        #expect(fallback.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == nil)
        let body = try #require(http.bodyJSON(of: fallback))
        #expect(body["context"]?["client"]?["clientName"]?.string == "WEB")
        #expect(body["context"]?["client"]?["visitorData"] == nil)
    }

    @Test func httpErrorMaps() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try Fixture.data("sw_js_data.txt"))
        http.enqueue("youtubei/v1/player", status: 500, body: Data("oops".utf8))
        let client = makeClient(http)
        await #expect(throws: NoSlopError.http(status: 500)) {
            _ = try await client.post(endpoint: "player", profile: .visionOS, body: ["videoId": "aqz-KE-bpKQ"])
        }
    }

    // MARK: Request building

    @Test func webProfileRequestShape() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try Fixture.data("sw_js_data.txt"))
        http.enqueue("youtubei/v1/search", body: Data("{}".utf8))
        let client = makeClient(http, config: InnerTubeConfig(hl: "de", gl: "DE"))

        _ = try await client.post(endpoint: "search", profile: .web, body: ["query": "blender"])

        let visitorData = try await client.visitorData()
        let request = try #require(requests(http, containing: "youtubei/v1/search").first)
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")
        #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "1")
        #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Version") == "2.20261030.02.00")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasSuffix(",gzip(gfe)") == true)
        #expect(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == visitorData)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.youtube.com")

        let body = try #require(http.bodyJSON(of: request))
        let contextClient = try #require(body["context"]?["client"])
        #expect(contextClient["clientName"]?.string == "WEB")
        #expect(contextClient["clientVersion"]?.string == "2.20261030.02.00")
        #expect(contextClient["hl"]?.string == "de")
        #expect(contextClient["gl"]?.string == "DE")
        #expect(contextClient["visitorData"]?.string == visitorData)
        // The WEB profile has no device fields.
        #expect(contextClient["deviceModel"] == nil)
        #expect(body["query"]?.string == "blender")
    }

    @Test func endpointsMayContainSlashes() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try Fixture.data("sw_js_data.txt"))
        http.enqueue("navigation/resolve_url", body: try Fixture.data("resolve_handle.json"))
        let client = makeClient(http)
        _ = try await client.post(endpoint: "navigation/resolve_url", profile: .web, body: ["url": "https://www.youtube.com/@x"])
        let request = try #require(requests(http, containing: "navigation/resolve_url").first)
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/navigation/resolve_url?prettyPrint=false")
    }

    @Test func theTransportOwnsTheContext() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/next", body: Data("{}".utf8))
        let client = makeClient(http)

        // A caller-supplied "context" must not be able to replace the client identity or the visitorData.
        let hostile: JSON = ["client": ["clientName": "ANDROID", "visitorData": "attacker"]]
        _ = try await client.post(endpoint: "next", profile: .web, body: ["context": hostile, "continuation": "TOKEN"])

        let request = try #require(requests(http, containing: "youtubei/v1/next").first)
        let body = try #require(http.bodyJSON(of: request))
        #expect(body["context"]?["client"]?["clientName"]?.string == "WEB")
        #expect(body["context"]?["client"]?["visitorData"]?.string == token(1))
        #expect(body["continuation"]?.string == "TOKEN")
    }

    @Test func extraClientFieldsNeverOverrideTheConfiguredOnes() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/player", body: Data("{}".utf8))
        let client = makeClient(http)
        let profile = ClientProfile(
            clientName: "TEST", clientVersion: "9.9", clientNameID: 7, userAgent: "UA/1",
            extraClientFields: ["hl": "xx", "visitorData": "nope", "deviceMake": "Acme"]
        )
        _ = try await client.post(endpoint: "player", profile: profile, body: [:])

        let request = try #require(requests(http, containing: "youtubei/v1/player").first)
        let fields = try #require(http.bodyJSON(of: request)?["context"]?["client"])
        #expect(fields["hl"]?.string == "en")
        #expect(fields["visitorData"]?.string == token(1))
        #expect(fields["deviceMake"]?.string == "Acme")
        #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "7")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "UA/1")
    }

    // MARK: Responses and errors

    @Test(arguments: [400, 403, 404, 429, 503])
    func nonSuccessStatusesBecomeHTTPErrors(status: Int) async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/browse", status: status, body: Data(#"{"error":{"code":1}}"#.utf8))
        let client = makeClient(http)
        await #expect(throws: NoSlopError.http(status: status)) {
            _ = try await client.post(endpoint: "browse", profile: .web, body: ["browseId": "x"])
        }
    }

    @Test func aBodyThatIsNotJSONThrowsDecoding() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/browse", body: Data("<html>captive portal</html>".utf8))
        let client = makeClient(http)
        do {
            _ = try await client.post(endpoint: "browse", profile: .web, body: [:])
            Issue.record("expected a decoding error")
        } catch let error as NoSlopError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test func transportFailuresPropagateUnchanged() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueueError("youtubei/v1/search", NoSlopError.network("offline"))
        let client = makeClient(http)
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await client.post(endpoint: "search", profile: .web, body: [:])
        }
    }

    // MARK: visitorData

    @Test func swJsDataIsFetchedWithASafariUserAgent() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        _ = try await makeClient(http).visitorData()
        let request = try #require(requests(http, containing: "sw.js_data").first)
        #expect(request.url?.absoluteString == "https://www.youtube.com/sw.js_data")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == ClientProfile.web.userAgent)
    }

    @Test func forceRefreshFetchesANewToken() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(2)))
        let client = makeClient(http)

        #expect(try await client.visitorData() == token(1))
        #expect(try await client.visitorData() == token(1))
        #expect(requests(http, containing: "sw.js_data").count == 1)
        #expect(try await client.visitorData(forceRefresh: true) == token(2))
        #expect(requests(http, containing: "sw.js_data").count == 2)
        // The refreshed token is the one in use from now on.
        #expect(try await client.visitorData() == token(2))
        #expect(requests(http, containing: "sw.js_data").count == 2)
    }

    @Test func concurrentCallersShareOneFetch() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        let client = makeClient(http)
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask { try await client.visitorData() }
            }
            var all: [String] = []
            for try await value in group { all.append(value) }
            return all
        }
        #expect(values.count == 12)
        #expect(Set(values) == [token(1)])
        #expect(requests(http, containing: "sw.js_data").count == 1)
    }

    @Test func aFreshTokenInTheStoreIsUsedWithoutTheNetwork() async throws {
        let clock = TransportTestClock()
        let store = InMemoryVisitorDataStore()
        store.save(value: token(7), fetchedAt: clock.now.addingTimeInterval(-3 * day))
        let http = MockHTTPClient()
        let client = makeClient(http, store: store, clock: clock)
        #expect(try await client.visitorData() == token(7))
        #expect(http.requests.isEmpty)
    }

    @Test func aStaleTokenInTheStoreIsReplaced() async throws {
        let clock = TransportTestClock()
        let store = InMemoryVisitorDataStore()
        store.save(value: token(7), fetchedAt: clock.now.addingTimeInterval(-8 * day))
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(8)))
        let client = makeClient(http, store: store, clock: clock)
        #expect(try await client.visitorData() == token(8))
        // …and the replacement is persisted with the time it was fetched.
        #expect(store.load()?.value == token(8))
        #expect(store.load()?.fetchedAt == clock.now)
    }

    @Test func aTokenFromTheFutureIsNotTrusted() async throws {
        let clock = TransportTestClock()
        let store = InMemoryVisitorDataStore()
        store.save(value: token(7), fetchedAt: clock.now.addingTimeInterval(30 * day))
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(8)))
        let client = makeClient(http, store: store, clock: clock)
        #expect(try await client.visitorData() == token(8))
    }

    @Test func aSecondClientReusesWhatTheFirstOnePersisted() async throws {
        let store = InMemoryVisitorDataStore()
        let first = MockHTTPClient()
        first.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(3)))
        _ = try await makeClient(first, store: store).visitorData()

        let second = MockHTTPClient()
        #expect(try await makeClient(second, store: store).visitorData() == token(3))
        #expect(second.requests.isEmpty)
    }

    @Test func percentEncodedTokensAreDecoded() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1) + "%3D%3D"))
        #expect(try await makeClient(http).visitorData() == token(1) + "==")
    }

    @Test func whenBothSourcesFailTheFallbackErrorIsThrown() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", status: 503, body: Data())
        http.enqueue("youtubei/v1/visitor_id", status: 500, body: Data())
        let client = makeClient(http)
        await #expect(throws: NoSlopError.http(status: 500)) {
            _ = try await client.visitorData()
        }
        // Nothing was cached, so the next call tries again.
        await #expect(throws: NoSlopError.http(status: 500)) {
            _ = try await client.visitorData()
        }
        #expect(requests(http, containing: "sw.js_data").count == 2)
    }

    @Test func aVisitorIdAnswerWithoutATokenIsADecodingError() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: Data("<html></html>".utf8))
        http.enqueue("youtubei/v1/visitor_id", body: Data(#"{"responseContext":{}}"#.utf8))
        let client = makeClient(http)
        do {
            _ = try await client.visitorData()
            Issue.record("expected a decoding error")
        } catch let error as NoSlopError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test func aFailedFetchIsNotCachedAndTheNextCallRecovers() async throws {
        let http = MockHTTPClient()
        http.enqueueError("sw.js_data", NoSlopError.network("offline"))
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(5)))
        let client = makeClient(http)
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await client.visitorData()
        }
        #expect(try await client.visitorData() == token(5))
    }
}

// MARK: - SwJsDataParser

@Suite struct TransportSwJsDataParserTests {
    @Test func takesTheTokenFromItsUsualPlace() throws {
        let text = String(decoding: try swJsDataBody(visitorData: token(1)), as: UTF8.self)
        #expect(SwJsDataParser.visitorData(from: text) == token(1))
    }

    @Test func findsTheTokenAnywhereWhenTheStructureMoves() {
        let text = ")]}'\n\n" + #"[["yt.sw.adr",null,[["something",["Mozilla/5.0 (Macintosh)","\#(token(2))"]]]]]"#
        #expect(SwJsDataParser.visitorData(from: text) == token(2))
    }

    @Test func prefersTheUsualPlaceOverALaterLookalike() throws {
        var inner = [JSON](repeating: .null, count: 20)
        inner[13] = .string(token(1))
        inner[19] = .string(token(9))
        let document = JSON.array([.array([.string("yt.sw.adr"), .null, .array([.array([.array(inner)])])])])
        let text = ")]}'\n" + String(decoding: try document.data(), as: UTF8.self)
        #expect(SwJsDataParser.visitorData(from: text) == token(1))
    }

    @Test func scansTheRawTextWhenTheJSONIsBroken() {
        let text = ")]}'\n\n" + #"[["yt.sw.adr",null,[[["sv","SE","\#(token(3))","# // truncated: never closed
        #expect(SwJsDataParser.visitorData(from: text) == token(3))
    }

    @Test func ignoresStringsThatOnlyLookALittleLikeATokenInTheFallback() {
        let text = #"[["Cg","CgTooShort","Cg with spaces and more than twenty characters","cgLowercasePrefix0123456789"]]"#
        #expect(SwJsDataParser.visitorData(from: text) == nil)
    }

    @Test(arguments: ["", "   ", "<html>not json</html>", ")]}'", ")]}'\n\n[]", ")]}'\n[[\"yt.sw.adr\",null,[]]]", "null"])
    func returnsNilWithoutAToken(text: String) {
        #expect(SwJsDataParser.visitorData(from: text) == nil)
    }
}

// MARK: - Visitor data stores

@Suite struct TransportVisitorDataStoreTests {
    /// A fresh suite per test: tests run in parallel and must not share state.
    private func freshDefaults() throws -> (UserDefaults, String) {
        let name = UUID().uuidString
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func userDefaultsStoreRoundTrips() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsVisitorDataStore(defaults: defaults, key: "vd")
        #expect(store.load() == nil)

        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_123.5)
        store.save(value: token(1), fetchedAt: fetchedAt)
        let loaded = try #require(store.load())
        #expect(loaded.value == token(1))
        #expect(loaded.fetchedAt == fetchedAt)

        // A new instance on the same defaults sees it (this is what survives an app restart).
        let again = try #require(UserDefaultsVisitorDataStore(defaults: defaults, key: "vd").load())
        #expect(again.value == token(1))
    }

    @Test func userDefaultsStoreKeepsKeysApart() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        UserDefaultsVisitorDataStore(defaults: defaults, key: "a").save(value: token(1), fetchedAt: Date())
        #expect(UserDefaultsVisitorDataStore(defaults: defaults, key: "b").load() == nil)
    }

    @Test func userDefaultsStoreOverwrites() throws {
        let (defaults, name) = try freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsVisitorDataStore(defaults: defaults, key: "vd")
        store.save(value: token(1), fetchedAt: Date(timeIntervalSince1970: 1))
        store.save(value: token(2), fetchedAt: Date(timeIntervalSince1970: 2))
        #expect(store.load()?.value == token(2))
        #expect(store.load()?.fetchedAt == Date(timeIntervalSince1970: 2))
    }

    @Test func userDefaultsStoreIgnoresMalformedData() throws {
        let malformed: [Any] = [
            42,
            "junk",
            ["value": 5] as [String: Any],
            ["fetchedAt": 5.0] as [String: Any],
            ["value": "", "fetchedAt": 5.0] as [String: Any],
        ]
        for stored in malformed {
            let (defaults, name) = try freshDefaults()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(stored, forKey: "vd")
            #expect(UserDefaultsVisitorDataStore(defaults: defaults, key: "vd").load() == nil, "stored: \(stored)")
        }
    }

    @Test func inMemoryStoreRoundTrips() {
        let store = InMemoryVisitorDataStore()
        #expect(store.load() == nil)
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store.save(value: token(1), fetchedAt: fetchedAt)
        #expect(store.load()?.value == token(1))
        #expect(store.load()?.fetchedAt == fetchedAt)
        store.save(value: token(2), fetchedAt: fetchedAt.addingTimeInterval(1))
        #expect(store.load()?.value == token(2))
    }

    @Test func inMemoryStoreIsSafeFromManyThreads() async {
        let store = InMemoryVisitorDataStore()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    store.save(value: token(index), fetchedAt: Date())
                    _ = store.load()
                }
            }
        }
        #expect(store.load() != nil)
    }
}

// MARK: - Configuration and profiles

@Suite struct TransportConfigTests {
    @Test func configFromLocale() {
        #expect(InnerTubeConfig.fromLocale(Locale(identifier: "de_DE")) == InnerTubeConfig(hl: "de", gl: "DE"))
        #expect(InnerTubeConfig.fromLocale(Locale(identifier: "pt_BR")) == InnerTubeConfig(hl: "pt", gl: "BR"))
        #expect(InnerTubeConfig.fromLocale(Locale(identifier: "en_US")) == InnerTubeConfig(hl: "en", gl: "US"))
    }

    @Test func configDefaultsTheRegionToUS() {
        #expect(InnerTubeConfig.fromLocale(Locale(identifier: "fr")) == InnerTubeConfig(hl: "fr", gl: "US"))
    }

    @Test func profilesMatchTheSpecTable() {
        let web = ClientProfile.web
        #expect(web.clientName == "WEB")
        #expect(web.clientVersion == "2.20261030.02.00")
        #expect(web.clientNameID == 1)
        #expect(web.userAgent == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15,gzip(gfe)")
        #expect(web.extraClientFields.isEmpty)

        let vision = ClientProfile.visionOS
        #expect(vision.clientName == "VISIONOS")
        #expect(vision.clientVersion == "1.02")
        #expect(vision.clientNameID == 101)
        #expect(vision.userAgent == "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15")
        #expect(vision.extraClientFields == [
            "deviceMake": "Apple",
            "deviceModel": "RealityDevice17,1",
            "osName": "visionOS",
            "osVersion": "26.5.23O471",
        ])
    }

    @Test func theClientExposesItsConfigurationWithoutAwait() {
        let client = InnerTubeClient(http: MockHTTPClient(), config: InnerTubeConfig(hl: "nl", gl: "NL"), visitorStore: InMemoryVisitorDataStore())
        #expect(client.config == InnerTubeConfig(hl: "nl", gl: "NL"))
    }
}
