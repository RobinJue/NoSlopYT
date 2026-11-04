import Foundation
import Testing
@testable import NoSlopKit

// These tests pin the requests the facade sends (endpoint, body, headers, client profile, continuation).
// What the parsers make of the answers is tested with the parsers and in Integration/FacadeIntegrationTests; here
// the answers only have to be ones the real parsers accept. The requests that must produce a page (a watch page, a
// channel, a playlist) are answered with the captured response and awaited without `try?`, so a request the parsers
// cannot make sense of fails the test instead of passing unnoticed; the others are answered with "{}", an empty page.

// MARK: - Helpers

private let handleURL = URL(string: "https://www.youtube.com/@BlenderOfficial")!

private func token(_ n: Int) -> String {
    "CgSyntheticVisitorData" + String(format: "%04d", n)
}

private func swJsDataBody(visitorData: String) throws -> Data {
    var inner = [JSON](repeating: .null, count: 14)
    inner[13] = .string(visitorData)
    let document = JSON.array([.array([.string("yt.sw.adr"), .null, .array([.array([.array(inner)])])])])
    return Data(")]}'\n\n".utf8) + (try document.data())
}

/// A mock that answers the visitorData fetch, then every InnerTube endpoint with `{}`, except the ones in `answers`
/// (endpoint → fixture name), which get the captured response.
private func makeHTTP(answers: [String: String] = [:]) throws -> MockHTTPClient {
    let http = MockHTTPClient()
    http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
    // Replies are matched in the order they were queued, so the specific ones come before the catch-all.
    for (endpoint, fixture) in answers.sorted(by: { $0.key < $1.key }) {
        http.enqueue("youtubei/v1/\(endpoint)", body: try Fixture.data(fixture))
    }
    http.enqueue("youtubei/v1/", body: Data("{}".utf8))
    return http
}

private func makeService(_ http: MockHTTPClient, hl: String = "en", gl: String = "US") -> InnerTubeYouTubeService {
    let client = InnerTubeClient(http: http, config: InnerTubeConfig(hl: hl, gl: gl), visitorStore: InMemoryVisitorDataStore())
    return InnerTubeYouTubeService(client: client, http: http)
}

/// The InnerTube requests sent to `endpoint`, e.g. "browse" or "navigation/resolve_url".
private func calls(_ http: MockHTTPClient, to endpoint: String) -> [URLRequest] {
    http.requests.filter { $0.url?.path == "/youtubei/v1/\(endpoint)" }
}

private func onlyCall(_ http: MockHTTPClient, to endpoint: String) throws -> (request: URLRequest, body: JSON) {
    let matching = calls(http, to: endpoint)
    #expect(matching.count == 1, "expected exactly one \(endpoint) request, got \(matching.count)")
    let request = try #require(matching.first)
    let body = try #require(http.bodyJSON(of: request))
    return (request, body)
}

@Suite struct FacadeRequestTests {
    // MARK: Search

    @Test func searchRequest() async throws {
        let http = try makeHTTP()
        let filter = SearchFilter(type: .video)
        _ = try await makeService(http).search(query: "blender", filter: filter)

        let (request, body) = try onlyCall(http, to: "search")
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")
        #expect(request.httpMethod == "POST")
        #expect(body["query"]?.string == "blender")
        // The protobuf for "videos only", spelled out: comparing with `SearchParams.encode(filter)` alone would pass
        // when both sides are nil.
        #expect(body["params"]?.string == "EgIQAQ==")
        #expect(body["params"]?.string == SearchParams.encode(filter))
        #expect(body["context"]?["client"]?["clientName"]?.string == "WEB")
        #expect(body["continuation"] == nil)
    }

    @Test(arguments: [
        (SearchFilter(type: .channel), "EgIQAg=="),
        (SearchFilter(type: .playlist), "EgIQAw=="),
        (SearchFilter(type: .video, sort: .uploadDate), "CAISAhAB"),
        (SearchFilter(sort: .viewCount), "CAM="),
        (SearchFilter(type: .video, duration: .long), "EgQQARgC"),
        (SearchFilter(type: .video, uploadDate: .today), "EgQIAhAB"),
    ])
    func searchSendsTheEncodedFilter(filter: SearchFilter, params: String) async throws {
        let http = try makeHTTP()
        _ = try await makeService(http).search(query: "blender", filter: filter)
        let (_, body) = try onlyCall(http, to: "search")
        #expect(body["params"]?.string == params)
    }

    @Test func queriesWithSpecialCharactersSurviveTheJSONBody() async throws {
        let http = try makeHTTP()
        let query = "größe 日本語 🎬 \"quoted\" back\\slash\nnew line\ttab </script> \u{0007}"
        _ = try await makeService(http).search(query: query, filter: SearchFilter())
        let (_, body) = try onlyCall(http, to: "search")
        #expect(body["query"]?.string == query)
    }

    @Test func searchWithTheDefaultFilterSendsNoParams() async throws {
        let http = try makeHTTP()
        _ = try await makeService(http).search(query: "blender", filter: SearchFilter())
        let (_, body) = try onlyCall(http, to: "search")
        #expect(body["params"] == nil)
        #expect(body["query"]?.string == "blender")
    }

    @Test func searchMoreSendsTheContinuationToken() async throws {
        let http = try makeHTTP()
        _ = try await makeService(http).searchMore(continuation: "EqkDEgdibGVuZGVy")
        let (request, body) = try onlyCall(http, to: "search")
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")
        #expect(body["continuation"]?.string == "EqkDEgdibGVuZGVy")
        #expect(body["query"] == nil)
        #expect(body["context"]?["client"]?["clientName"]?.string == "WEB")
    }

    // MARK: Suggestions (a plain GET, not InnerTube)

    @Test func suggestionsRequest() async throws {
        let http = MockHTTPClient()
        http.enqueue("suggestqueries.google.com", body: try Fixture.data("suggest_firefox.json"))
        let service = makeService(http)

        let suggestions = try await service.suggestions(for: "blender tut")

        #expect(suggestions.count == 10)
        #expect(suggestions.first == "blender tutorial")
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&hl=en&gl=US&q=blender%20tut")
        // Suggestions need no visitorData, so nothing but the one GET went out.
        #expect(http.requests.count == 1)
    }

    @Test func suggestionsUseTheConfiguredLanguageAndRegion() async throws {
        let http = MockHTTPClient()
        http.enqueue("suggestqueries.google.com", body: try Fixture.data("suggest_firefox.json"))
        _ = try await makeService(http, hl: "de", gl: "AT").suggestions(for: "kochen")
        #expect(http.requests.first?.url?.absoluteString == "https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&hl=de&gl=AT&q=kochen")
    }

    @Test func suggestionQueriesAreEscapedStrictly() async throws {
        let http = MockHTTPClient()
        http.enqueue("suggestqueries.google.com", body: try Fixture.data("suggest_firefox.json"))
        _ = try await makeService(http).suggestions(for: "c++ & more/Ü=#?")
        // "+", "&", "=", "#", "?" and "/" would change the meaning of the query string if left alone.
        #expect(http.requests.first?.url?.absoluteString.hasSuffix("&q=c%2B%2B%20%26%20more%2F%C3%9C%3D%23%3F") == true)
    }

    @Test(arguments: ["", " ", "   ", "\t\n"])
    func blankSuggestionQueriesSendNothing(query: String) async throws {
        let http = MockHTTPClient()
        #expect(try await makeService(http).suggestions(for: query).isEmpty)
        #expect(http.requests.isEmpty)
    }

    @Test func suggestionsHTTPErrorsMap() async throws {
        let http = MockHTTPClient()
        http.enqueue("suggestqueries.google.com", status: 503, body: Data())
        let service = makeService(http)
        await #expect(throws: NoSlopError.http(status: 503)) {
            _ = try await service.suggestions(for: "blender")
        }
    }

    @Test func suggestionsNetworkErrorsPropagate() async throws {
        let http = MockHTTPClient()
        http.enqueueError("suggestqueries.google.com", NoSlopError.network("offline"))
        let service = makeService(http)
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await service.suggestions(for: "blender")
        }
    }

    @Test func garbageSuggestionsAreAnEmptyList() async throws {
        let http = MockHTTPClient()
        http.enqueue("suggestqueries.google.com", body: Data("<html>captive portal</html>".utf8))
        #expect(try await makeService(http).suggestions(for: "blender").isEmpty)
    }

    // MARK: Watch page

    @Test func videoDetailsRequest() async throws {
        let http = try makeHTTP(answers: ["next": "next_aqz.json"])
        let details = try await makeService(http).videoDetails(id: "aqz-KE-bpKQ")
        #expect(details.id == "aqz-KE-bpKQ")
        let (request, body) = try onlyCall(http, to: "next")
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/next?prettyPrint=false")
        #expect(body["videoId"]?.string == "aqz-KE-bpKQ")
        #expect(body["continuation"] == nil)
        #expect(body["context"]?["client"]?["clientName"]?.string == "WEB")
    }

    @Test func moreRelatedSendsTheContinuationToNext() async throws {
        let http = try makeHTTP()
        _ = try await makeService(http).moreRelated(continuation: "RELATED-TOKEN")
        let (_, body) = try onlyCall(http, to: "next")
        #expect(body["continuation"]?.string == "RELATED-TOKEN")
        #expect(body["videoId"] == nil)
    }

    @Test func commentsSendTheContinuationToNext() async throws {
        let http = try makeHTTP()
        _ = try await makeService(http).comments(continuation: "COMMENTS-TOKEN")
        let (_, body) = try onlyCall(http, to: "next")
        #expect(body["continuation"]?.string == "COMMENTS-TOKEN")
        #expect(body["videoId"] == nil)
    }

    // MARK: Channels

    @Test func channelRequestAsksForTheVideosTab() async throws {
        let http = try makeHTTP(answers: ["browse": "channel_blender_videos.json"])
        let page = try await makeService(http).channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(page.header.id == "UCSMOQeBJ2RAnuFungnQOxLg")
        let (request, body) = try onlyCall(http, to: "browse")
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")
        #expect(body["browseId"]?.string == "UCSMOQeBJ2RAnuFungnQOxLg")
        // The params of the Videos tab, spelled out.
        #expect(body["params"]?.string == "EgZ2aWRlb3PyBgQKAjoA")
        #expect(body["params"]?.string == ChannelParser.tabParams[.videos])
    }

    @Test(arguments: [
        (ChannelTabKind.videos, "EgZ2aWRlb3PyBgQKAjoA"),
        (.live, "EgdzdHJlYW1z8gYECgJ6AA%3D%3D"),
        (.playlists, "EglwbGF5bGlzdHPyBgoKCEIGCgIQaCIA"),
    ])
    func channelTabRequestUsesThatTabsParams(tab: ChannelTabKind, params: String) async throws {
        let http = try makeHTTP()
        _ = try await makeService(http).channelTab(channelID: "UCSMOQeBJ2RAnuFungnQOxLg", tab: tab)
        let (_, body) = try onlyCall(http, to: "browse")
        #expect(body["browseId"]?.string == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(body["params"]?.string == params)
        #expect(body["params"]?.string == ChannelParser.tabParams[tab])
    }

    @Test func everyTabHasParams() {
        #expect(Set(ChannelTabKind.allCases) == [.videos, .live, .playlists])
        #expect(ChannelTabKind.allCases.allSatisfy { ChannelParser.tabParams[$0]?.isEmpty == false })
    }

    @Test func channelMoreSendsTheContinuationToBrowse() async throws {
        let http = try makeHTTP()
        _ = try await makeService(http).channelMore(continuation: "CHANNEL-TOKEN")
        let (_, body) = try onlyCall(http, to: "browse")
        #expect(body["continuation"]?.string == "CHANNEL-TOKEN")
        #expect(body["browseId"] == nil)
        #expect(body["params"] == nil)
    }

    // MARK: Playlists

    @Test func playlistRequestBrowsesTheVLPrefixedId() async throws {
        let http = try makeHTTP(answers: ["browse": "playlist_sample.json"])
        let page = try await makeService(http).playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        #expect(page.info.id == "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        let (_, body) = try onlyCall(http, to: "browse")
        #expect(body["browseId"]?.string == "VLPLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        #expect(body["params"] == nil)
    }

    @Test func playlistMoreSendsTheContinuationToBrowse() async throws {
        let http = try makeHTTP()
        _ = try await makeService(http).playlistMore(continuation: "PLAYLIST-TOKEN")
        let (_, body) = try onlyCall(http, to: "browse")
        #expect(body["continuation"]?.string == "PLAYLIST-TOKEN")
        #expect(body["browseId"] == nil)
    }

    // MARK: Resolving links

    @Test func resolveHandleAsksTheNetwork() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("navigation/resolve_url", body: try Fixture.data("resolve_handle.json"))

        let resolved = try await makeService(http).resolve(url: handleURL)

        #expect(resolved == .channel(id: "UCSMOQeBJ2RAnuFungnQOxLg"))
        let (request, body) = try onlyCall(http, to: "navigation/resolve_url")
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/navigation/resolve_url?prettyPrint=false")
        #expect(body["url"]?.string == "https://www.youtube.com/@BlenderOfficial")
        #expect(body["context"]?["client"]?["clientName"]?.string == "WEB")
    }

    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg",
        "https://www.youtube.com/playlist?list=PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B",
        "noslop://search?q=blender",
    ])
    func linksThatCanBeRecognisedLocallyNeverTouchTheNetwork(text: String) async throws {
        let http = MockHTTPClient()
        let resolved = try await makeService(http).resolve(url: try #require(URL(string: text)))
        #expect(resolved == YouTubeURL.resolveLocally(try #require(URL(string: text))))
        #expect(resolved != nil)
        #expect(http.requests.isEmpty)
    }

    @Test(arguments: [
        "https://example.com/@BlenderOfficial",
        "https://vimeo.com/123456789",
        "mailto:someone@example.com",
        "noslop://tab/home",
    ])
    func foreignLinksAreNeverSentToYouTube(text: String) async throws {
        let http = MockHTTPClient()
        let resolved = try await makeService(http).resolve(url: try #require(URL(string: text)))
        #expect(resolved == nil)
        #expect(http.requests.isEmpty)
    }

    @Test func aHandleThatDoesNotExistResolvesToNil() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("navigation/resolve_url", status: 404, body: Data(#"{"error":{"code":404,"status":"NOT_FOUND"}}"#.utf8))
        #expect(try await makeService(http).resolve(url: handleURL) == nil)
    }

    @Test(arguments: ["https://www.youtube.com/@", "https://www.youtube.com/@@", "https://www.youtube.com/c/", "https://m.youtube.com/@%20"])
    func aMalformedLinkResolvesToNil(text: String) async throws {
        // YouTube answers HTTP 400 (INVALID_ARGUMENT) for a link that is not well-formed, where it answers 404 for one
        // that is well-formed but leads nowhere. Neither is an error of the app or of the network.
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue(
            "navigation/resolve_url", status: 400,
            body: Data(#"{"error":{"code":400,"message":"Request contains an invalid argument.","status":"INVALID_ARGUMENT"}}"#.utf8)
        )
        let url = try #require(URL(string: text))

        #expect(try await makeService(http).resolve(url: url) == nil)

        let (_, body) = try onlyCall(http, to: "navigation/resolve_url")
        #expect(body["url"]?.string == text, "the link did go to YouTube; it was YouTube that did not understand it")
    }

    @Test(arguments: [401, 403, 429, 500, 502, 503])
    func otherResolveFailuresPropagate(status: Int) async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("navigation/resolve_url", status: status, body: Data())
        let service = makeService(http)
        await #expect(throws: NoSlopError.http(status: status)) {
            _ = try await service.resolve(url: handleURL)
        }
    }

    @Test func anUnrecognisedAnswerResolvesToNil() async throws {
        let http = try makeHTTP()
        #expect(try await makeService(http).resolve(url: handleURL) == nil)
    }

    // MARK: Shared transport behaviour

    @Test func everyMetadataRequestUsesTheWebProfileAndTheSameVisitorData() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        // The watch page is answered once and the requests to browse in the order the calls below make them: a channel,
        // a tab, a continuation, a playlist, a continuation. Everything else is an empty page.
        http.enqueue("youtubei/v1/next", body: try Fixture.data("next_aqz.json"))
        http.enqueue("youtubei/v1/next", body: Data("{}".utf8))
        http.enqueue("youtubei/v1/browse", body: try Fixture.data("channel_blender_videos.json"))
        http.enqueue("youtubei/v1/browse", body: Data("{}".utf8))
        http.enqueue("youtubei/v1/browse", body: Data("{}".utf8))
        http.enqueue("youtubei/v1/browse", body: try Fixture.data("playlist_sample.json"))
        http.enqueue("youtubei/v1/browse", body: Data("{}".utf8))
        http.enqueue("youtubei/v1/", body: Data("{}".utf8))
        let service = makeService(http, hl: "fr", gl: "CA")
        _ = try await service.search(query: "q", filter: SearchFilter())
        _ = try await service.searchMore(continuation: "c1")
        _ = try await service.videoDetails(id: "aqz-KE-bpKQ")
        _ = try await service.moreRelated(continuation: "c2")
        _ = try await service.comments(continuation: "c3")
        _ = try await service.channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")
        _ = try await service.channelTab(channelID: "UCSMOQeBJ2RAnuFungnQOxLg", tab: .playlists)
        _ = try await service.channelMore(continuation: "c4")
        _ = try await service.playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        _ = try await service.playlistMore(continuation: "c5")

        let youtubei = http.requests.filter { $0.url?.path.hasPrefix("/youtubei/v1/") == true }
        #expect(youtubei.count == 10)
        for request in youtubei {
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "1")
            #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Version") == "2.20261030.02.00")
            #expect(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == token(1))
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.youtube.com")
            let client = http.bodyJSON(of: request)?["context"]?["client"]
            #expect(client?["clientName"]?.string == "WEB")
            #expect(client?["hl"]?.string == "fr")
            #expect(client?["gl"]?.string == "CA")
            #expect(client?["visitorData"]?.string == token(1))
        }
        // One visitorData fetch served them all.
        #expect(http.requests.filter { $0.url?.absoluteString.contains("sw.js_data") == true }.count == 1)
    }

    @Test func serverErrorsSurfaceAsHTTPErrors() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/search", status: 400, body: Data())
        let service = makeService(http)
        await #expect(throws: NoSlopError.http(status: 400)) {
            _ = try await service.search(query: "x", filter: SearchFilter())
        }
    }
}

// MARK: - Facade logic with fake parsers
//
// The real parsers belong to Tasks 3 and 4. Here every parser is replaced by a fake that labels its output with
// the "marker" field of the response, so the tests show which parser each facade method used, and the facade's own
// rules (caching, merging, nil to error) hold whatever the real parsers do.

private let marked = Data(#"{"marker":"M"}"#.utf8)

private func label(_ json: JSON) -> String {
    json["marker"]?.string ?? "?"
}

private func fakeVideo(_ id: String) -> VideoSummary {
    VideoSummary(id: id, title: id)
}

private func fakeParsers() -> YouTubeParsers {
    YouTubeParsers(
        search: { Page(items: [.video(fakeVideo("search:\(label($0))"))], continuation: "search-next") },
        watch: { json, id in
            VideoDetails(id: id, title: "watch:\(label(json))", channel: ChannelRef(id: "UC1", name: "Channel"))
        },
        related: { Page(items: [fakeVideo("related:\(label($0))")], continuation: "related-next") },
        relatedContinuation: { Page(items: [fakeVideo("relatedMore:\(label($0))")], continuation: "relatedMore-next") },
        comments: { CommentsPage(comments: [], continuation: "comments:\(label($0))") },
        channelPage: {
            ChannelPage(header: ChannelHeader(id: "UC1", name: "channelPage:\(label($0))"), availableTabs: [.videos], videos: Page())
        },
        channelTab: { Page(items: [.video(fakeVideo("channelTab:\(label($0))"))]) },
        channelContinuation: { Page(items: [.video(fakeVideo("channelMore:\(label($0))"))]) },
        playlist: { json, id in
            PlaylistPage(info: PlaylistSummary(id: id, title: "playlist:\(label(json))"), videos: Page())
        },
        playlistContinuation: { Page(items: [fakeVideo("playlistMore:\(label($0))")]) }
    )
}

private final class FacadeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Collects values from `@Sendable` closures.
private final class IDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var ids: [String] { lock.withLock { recorded } }
    func record(_ id: String) { lock.withLock { recorded.append(id) } }
}

private func makeFakedService(
    _ http: MockHTTPClient,
    parsers: YouTubeParsers = fakeParsers(),
    clock: FacadeTestClock = FacadeTestClock()
) -> InnerTubeYouTubeService {
    let client = InnerTubeClient(http: http, config: InnerTubeConfig(hl: "en", gl: "US"), visitorStore: InMemoryVisitorDataStore())
    return InnerTubeYouTubeService(client: client, http: http, parsers: parsers, now: { clock.now })
}

private func makeMarkedHTTP() throws -> MockHTTPClient {
    let http = MockHTTPClient()
    http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
    http.enqueue("youtubei/v1/", body: marked)
    return http
}

@Suite struct FacadeRequestParserWiringTests {
    @Test func everyMethodHandsTheAnswerToItsOwnParser() async throws {
        let service = makeFakedService(try makeMarkedHTTP())

        #expect(try await service.search(query: "q", filter: SearchFilter()).items.first?.video?.id == "search:M")
        #expect(try await service.searchMore(continuation: "c").items.first?.video?.id == "search:M")
        #expect(try await service.moreRelated(continuation: "c").items.first?.id == "relatedMore:M")
        #expect(try await service.comments(continuation: "c").continuation == "comments:M")
        #expect(try await service.channel(id: "UC1").header.name == "channelPage:M")
        #expect(try await service.channelTab(channelID: "UC1", tab: .live).items.first?.video?.id == "channelTab:M")
        #expect(try await service.channelMore(continuation: "c").items.first?.video?.id == "channelMore:M")
        #expect(try await service.playlist(id: "PL1").info.title == "playlist:M")
        #expect(try await service.playlistMore(continuation: "c").items.first?.id == "playlistMore:M")
    }

    @Test func pagesKeepTheContinuationTheParserFound() async throws {
        let service = makeFakedService(try makeMarkedHTTP())
        #expect(try await service.search(query: "q", filter: SearchFilter()).continuation == "search-next")
        #expect(try await service.moreRelated(continuation: "c").continuation == "relatedMore-next")
    }

    @Test func playlistIsParsedWithThePlaylistIdNotTheBrowseId() async throws {
        let seen = IDRecorder()
        var parsers = fakeParsers()
        parsers.playlist = { _, id in
            seen.record(id)
            return PlaylistPage(info: PlaylistSummary(id: id, title: "t"), videos: Page())
        }
        _ = try await makeFakedService(try makeMarkedHTTP(), parsers: parsers).playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        #expect(seen.ids == ["PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"])
    }

    // MARK: Video details

    @Test func videoDetailsCarryTheRelatedVideosOfTheSameAnswer() async throws {
        let service = makeFakedService(try makeMarkedHTTP())
        let details = try await service.videoDetails(id: "aqz-KE-bpKQ")
        #expect(details.id == "aqz-KE-bpKQ")
        #expect(details.title == "watch:M")
        #expect(details.related.map(\.id) == ["related:M"])
        #expect(details.relatedContinuation == "related-next")
    }

    @Test func videoDetailsAreCachedForTenMinutes() async throws {
        let clock = FacadeTestClock()
        let http = try makeMarkedHTTP()
        let service = makeFakedService(http, clock: clock)

        let first = try await service.videoDetails(id: "aqz-KE-bpKQ")
        clock.advance(by: 9 * 60 + 59)
        let second = try await service.videoDetails(id: "aqz-KE-bpKQ")
        #expect(second == first)
        #expect(calls(http, to: "next").count == 1)

        clock.advance(by: 2)
        _ = try await service.videoDetails(id: "aqz-KE-bpKQ")
        #expect(calls(http, to: "next").count == 2)
        // …and the refreshed entry is cached again.
        _ = try await service.videoDetails(id: "aqz-KE-bpKQ")
        #expect(calls(http, to: "next").count == 2)
    }

    @Test func theDetailsCacheIsPerVideo() async throws {
        let http = try makeMarkedHTTP()
        let service = makeFakedService(http)
        let a = try await service.videoDetails(id: "aaaaaaaaaaa")
        let b = try await service.videoDetails(id: "bbbbbbbbbbb")
        #expect(a.id == "aaaaaaaaaaa")
        #expect(b.id == "bbbbbbbbbbb")
        #expect(calls(http, to: "next").count == 2)
    }

    @Test func aWatchPageThatCannotBeParsedIsADecodingErrorAndIsNotCached() async throws {
        let http = try makeMarkedHTTP()
        var parsers = fakeParsers()
        parsers.watch = { _, _ in nil }
        let service = makeFakedService(http, parsers: parsers)
        for _ in 0..<2 {
            do {
                _ = try await service.videoDetails(id: "aqz-KE-bpKQ")
                Issue.record("expected a decoding error")
            } catch let error as NoSlopError {
                guard case .decoding = error else {
                    Issue.record("expected .decoding, got \(error)")
                    continue
                }
            }
        }
        #expect(calls(http, to: "next").count == 2)
    }

    @Test func aFailedRequestIsNotCached() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/next", status: 500, body: Data())
        http.enqueue("youtubei/v1/next", body: marked)
        let service = makeFakedService(http)
        await #expect(throws: NoSlopError.http(status: 500)) {
            _ = try await service.videoDetails(id: "aqz-KE-bpKQ")
        }
        #expect(try await service.videoDetails(id: "aqz-KE-bpKQ").title == "watch:M")
    }

    // MARK: Channels and playlists that cannot be read

    @Test func aChannelWithoutAHeaderIsADecodingError() async throws {
        var parsers = fakeParsers()
        parsers.channelPage = { _ in nil }
        let service = makeFakedService(try makeMarkedHTTP(), parsers: parsers)
        do {
            _ = try await service.channel(id: "UC1")
            Issue.record("expected a decoding error")
        } catch let error as NoSlopError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test func aPlaylistWithoutAHeaderIsADecodingError() async throws {
        var parsers = fakeParsers()
        parsers.playlist = { _, _ in nil }
        let service = makeFakedService(try makeMarkedHTTP(), parsers: parsers)
        do {
            _ = try await service.playlist(id: "PL1")
            Issue.record("expected a decoding error")
        } catch let error as NoSlopError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }

    @Test func emptyPagesAreNotErrors() async throws {
        var parsers = fakeParsers()
        parsers.search = { _ in Page() }
        parsers.channelTab = { _ in Page() }
        let service = makeFakedService(try makeMarkedHTTP(), parsers: parsers)
        #expect(try await service.search(query: "nothing", filter: SearchFilter()).items.isEmpty)
        #expect(try await service.channelTab(channelID: "UC1", tab: .playlists).items.isEmpty)
    }
}

// MARK: - Content that is gone
//
// A removed or private video, a deleted playlist and a terminated channel are answered with HTTP 200 and no usable
// page. YouTube says why in its own words: an ERROR alert (`alerts[].alertRenderer`, with `runs` for a playlist and
// `simpleText` for a channel) on `browse`, a `backgroundPromoRenderer` on `next`. The three fixtures are real
// answers (2026-11-04, hl=en, gl=US) for a playlist id, a channel id and a video id that do not exist, trimmed to the
// keys that matter.

@Suite struct FacadeUnavailableContentTests {
    private func serve(_ endpoint: String, _ body: Data) throws -> MockHTTPClient {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: try swJsDataBody(visitorData: token(1)))
        http.enqueue("youtubei/v1/\(endpoint)", body: body)
        return http
    }

    private func serve(_ endpoint: String, json text: String) throws -> MockHTTPClient {
        try serve(endpoint, Data(text.utf8))
    }

    private func alert(_ type: String, text: String) -> String {
        #"{"alertRenderer":{"type":"\#(type)","text":{"simpleText":"\#(text)"}}}"#
    }

    // MARK: The real answers

    @Test func aMissingPlaylistSaysSoInYouTubesWords() async throws {
        let service = makeService(try serve("browse", try Fixture.data("browse_playlist_missing.json")))
        await #expect(throws: NoSlopError.unavailable(reason: "The playlist does not exist.")) {
            _ = try await service.playlist(id: "PLzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
        }
    }

    @Test func aTerminatedChannelSaysSoInYouTubesWords() async throws {
        let service = makeService(try serve("browse", try Fixture.data("browse_channel_missing.json")))
        await #expect(throws: NoSlopError.unavailable(reason: "This channel does not exist.")) {
            _ = try await service.channel(id: "UCzzzzzzzzzzzzzzzzzzzzzz")
        }
    }

    @Test func aRemovedVideoSaysSoInYouTubesWordsAndIsNotCached() async throws {
        let http = try serve("next", try Fixture.data("next_video_missing.json"))
        let service = makeService(http)
        for _ in 0..<2 {
            await #expect(throws: NoSlopError.unavailable(reason: "This video isn't available anymore")) {
                _ = try await service.videoDetails(id: "aaaaaaaaaaa")
            }
        }
        // Each try asked YouTube again: a video that comes back (made public again) must not stay "gone" for ten minutes.
        #expect(calls(http, to: "next").count == 2)
    }

    @Test func theReasonIsShownAsItIs() async throws {
        let service = makeService(try serve("browse", try Fixture.data("browse_playlist_missing.json")))
        do {
            _ = try await service.playlist(id: "PLzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
            Issue.record("expected an error")
        } catch {
            #expect((error as? LocalizedError)?.errorDescription == "The playlist does not exist.")
            #expect((error as? NoSlopError)?.isWorthRetrying == false)
        }
    }

    // MARK: What is not a reason

    @Test(arguments: ["browse", "next"])
    func anAnswerWithNothingToSayIsStillADecodingError(endpoint: String) async throws {
        let service = makeService(try serve(endpoint, json: "{}"))
        await expectDecodingError {
            switch endpoint {
            case "browse": _ = try await service.playlist(id: "PL1")
            default: _ = try await service.videoDetails(id: "aaaaaaaaaaa")
            }
        }
        let channelService = makeService(try serve("browse", json: "{}"))
        await expectDecodingError { _ = try await channelService.channel(id: "UC1") }
    }

    @Test func onlyAnErrorAlertWithTextIsAReason() async throws {
        // A warning or an info alert, an error alert without text, and a wrong shape are no reason to say "gone".
        let oddAlerts = [
            #"{"alerts":[\#(alert("WARNING", text: "Be careful."))]}"#,
            #"{"alerts":[\#(alert("INFO", text: "Fyi."))]}"#,
            #"{"alerts":[{"alertRenderer":{"type":"ERROR"}}]}"#,
            #"{"alerts":[{"alertRenderer":{"type":"ERROR","text":{"simpleText":"   "}}}]}"#,
            #"{"alerts":[{"somethingElse":{}}, 5, null]}"#,
            #"{"alerts":{}}"#,
        ]
        for body in oddAlerts {
            let service = makeService(try serve("browse", json: body))
            await expectDecodingError { _ = try await service.playlist(id: "PL1") }
        }
    }

    @Test func theFirstErrorAlertWithTextWins() async throws {
        let body = #"{"alerts":[\#(alert("WARNING", text: "Careful.")),{"alertRenderer":{"type":"ERROR"}},\#(alert("ERROR", text: "This playlist is private.")),\#(alert("ERROR", text: "Second."))]}"#
        let service = makeService(try serve("browse", json: body))
        await #expect(throws: NoSlopError.unavailable(reason: "This playlist is private.")) {
            _ = try await service.playlist(id: "PL1")
        }
    }

    @Test func aBackgroundPromoIsOnlyAReasonOnTheWatchPage() async throws {
        // Browse pages have promos of their own ("sign in", empty states): they are not a reason there.
        let promo = #"{"contents":{"x":{"backgroundPromoRenderer":{"title":{"runs":[{"text":"Sign in to see more"}]}}}}}"#
        let playlistService = makeService(try serve("browse", json: promo))
        await expectDecodingError { _ = try await playlistService.playlist(id: "PL1") }
        let channelService = makeService(try serve("browse", json: promo))
        await expectDecodingError { _ = try await channelService.channel(id: "UC1") }

        // On the watch page the same renderer is how YouTube says that the video is gone.
        let watchService = makeService(try serve("next", json: promo))
        await #expect(throws: NoSlopError.unavailable(reason: "Sign in to see more")) {
            _ = try await watchService.videoDetails(id: "aaaaaaaaaaa")
        }
    }

    @Test func theWatchPageCanSayItWithAnErrorAlertToo() async throws {
        let service = makeService(try serve("next", json: #"{"alerts":[\#(alert("ERROR", text: "This video is private."))]}"#))
        await #expect(throws: NoSlopError.unavailable(reason: "This video is private.")) {
            _ = try await service.videoDetails(id: "aaaaaaaaaaa")
        }
    }

    // MARK: Healthy pages are left alone

    @Test func aPageThatCanBeReadIsNotSecondGuessed() async throws {
        // The alert is only looked at when the parser has nothing: a playlist with videos and a stray alert is a playlist.
        guard case .object(var object) = try Fixture.json("playlist_sample.json") else {
            Issue.record("playlist_sample.json is not an object")
            return
        }
        object["alerts"] = try JSON(data: Data("[\(alert("ERROR", text: "Something else."))]".utf8))
        let http = try serve("browse", try JSON.object(object).data())
        let page = try await makeService(http).playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        #expect(!page.videos.items.isEmpty)
    }

    // MARK: The error itself

    @Test func onlyUnavailableContentIsNotWorthRetrying() {
        #expect(!NoSlopError.unavailable(reason: "Gone.").isWorthRetrying)
        let retryable: [NoSlopError] = [
            .network("x"), .http(status: 500), .http(status: 404), .decoding("x"), .botCheck, .unplayable(reason: "Private."),
            .notPlayableYet(reason: "This live event will begin in 2 hours."), .notSignedIn, .googleNotConfigured, .oauth("x"), .quotaExceeded, .dataAPINotEnabled, .cancelled, .notImplemented("x"),
        ]
        for error in retryable {
            #expect(error.isWorthRetrying, "\(error)")
        }
        #expect(NoSlopError.unavailable(reason: "Gone.").errorDescription == "Gone.")
        #expect(NoSlopError.unavailable(reason: "Gone.") == .unavailable(reason: "Gone."))
        #expect(NoSlopError.unavailable(reason: "Gone.") != .unplayable(reason: "Gone."))
        #expect(NoSlopError.notPlayableYet(reason: "Soon.") != .unplayable(reason: "Soon."))
    }

    private func expectDecodingError(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected a decoding error")
        } catch let error as NoSlopError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        } catch {
            Issue.record("expected .decoding, got \(error)")
        }
    }
}
