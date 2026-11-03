import Foundation
import Testing
@testable import NoSlopKit

/// A clock the test moves by hand.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private func queryItems(of request: URLRequest) -> [String: String] {
    guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private func decodeStringArray(_ text: String?) -> [String]? {
    guard let text else { return nil }
    return try? JSONDecoder().decode([String].self, from: Data(text.utf8))
}

/// A prefix response for one video, in the shape of `api/skipSegments/<prefix>`.
private func response(videoID: String, segments: [String]) -> Data {
    Data(#"[{"videoID":"\#(videoID)","segments":[\#(segments.joined(separator: ","))]}]"#.utf8)
}

private func rawSegment(
    uuid: String = "uuid-1",
    category: String = "sponsor",
    action: String = "skip",
    start: Double = 10,
    end: Double = 20
) -> String {
    #"{"category":"\#(category)","actionType":"\#(action)","segment":[\#(start),\#(end)],"UUID":"\#(uuid)","videoDuration":300,"locked":0,"votes":1,"description":""}"#
}

/// An `HTTPClient` that answers every request with the same body after a delay and counts the requests, so that tests
/// can make lookups overlap.
private final class SlowHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0
    private let delay: Duration
    private let body: Data

    init(delay: Duration, body: Data) {
        self.delay = delay
        self.body = body
    }

    var requestCount: Int {
        lock.withLock { received }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { received += 1 }
        try await Task.sleep(for: delay)
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw NoSlopError.network("no response")
        }
        return (body, response)
    }
}

@Suite struct SponsorBlockTests {
    // MARK: Hash prefix

    @Test func hashPrefix() {
        #expect(HashPrefix.sha256Prefix("dQw4w9WgXcQ") == "5f6b")
    }

    @Test func hashPrefixIsLowercaseHexOfTheRequestedLength() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        #expect(HashPrefix.sha256Prefix("abc") == "ba78")
        #expect(HashPrefix.sha256Prefix("abc", length: 6) == "ba7816")
        #expect(HashPrefix.sha256Prefix("abc", length: 64) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(HashPrefix.sha256Prefix("abc", length: 0) == "")
        #expect(HashPrefix.sha256Prefix("abc", length: 500).count == 64)
        #expect(HashPrefix.sha256Prefix("1H8_tk_dMLw") == "5f6b")
    }

    // MARK: From the plan

    @Test func segmentsFromPrefixResponse() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", body: try Fixture.data("sponsorblock_prefix.json"))
        let client = SponsorBlockClient(http: http)

        let segments = try await client.segments(videoID: "1H8_tk_dMLw")

        #expect(segments == [
            SponsorSegment(
                id: "e366ae057345938a0f424144c689ab9ae92b690724e439b1c28c39201195502e7",
                category: .sponsor,
                actionType: .skip,
                start: 3.662,
                end: 36.322
            ),
        ])
        #expect(segments.first?.id.hasPrefix("e366ae05") == true)

        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "sponsor.ajay.app")
        #expect(request.url?.path == "/api/skipSegments/\(HashPrefix.sha256Prefix("1H8_tk_dMLw"))")
        #expect(request.url?.path == "/api/skipSegments/5f6b")

        let query = queryItems(of: request)
        let categories = try #require(decodeStringArray(query["categories"]))
        #expect(categories.count == 9)
        #expect(Set(categories) == Set(SponsorCategory.allCases.map(\.rawValue)))
        #expect(decodeStringArray(query["actionTypes"]) == ["skip", "mute", "poi"])
        #expect(query["actionTypes"] == #"["skip","mute","poi"]"#)
    }

    @Test func noSegmentsForVideoNotInResponse() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", body: try Fixture.data("sponsorblock_prefix.json"))
        let client = SponsorBlockClient(http: http)

        // Same hash prefix as 1H8_tk_dMLw, but the community has no segments for it.
        #expect(try await client.segments(videoID: "dQw4w9WgXcQ").isEmpty)
    }

    @Test func notFoundMeansNoSegments() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", status: 404, body: Data("Not Found".utf8))
        let client = SponsorBlockClient(http: http)

        #expect(try await client.segments(videoID: "dQw4w9WgXcQ").isEmpty)
    }

    // MARK: More lookups

    @Test func theWholePrefixResponseIsFilteredToTheRequestedVideo() async throws {
        let body = Data("""
        [{"videoID":"other","segments":[\(rawSegment(uuid: "other-1"))]},
         {"videoID":"mine","segments":[\(rawSegment(uuid: "mine-1", start: 50, end: 60)),\(rawSegment(uuid: "mine-2", category: "intro", start: 0, end: 12))]},
         {"videoID":"MINE","segments":[\(rawSegment(uuid: "case-1"))]}]
        """.utf8)
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", body: body)

        let segments = try await SponsorBlockClient(http: http).segments(videoID: "mine")

        // Sorted by start; the entries of other videos (including a different spelling) are not mixed in.
        #expect(segments.map(\.id) == ["mine-2", "mine-1"])
        #expect(segments.map(\.category) == [.intro, .sponsor])
    }

    @Test func everyActionTypeAndCategoryIsMapped() async throws {
        let segments = [
            rawSegment(uuid: "a", category: "selfpromo", action: "skip", start: 1, end: 5),
            rawSegment(uuid: "b", category: "music_offtopic", action: "mute", start: 10, end: 20),
            rawSegment(uuid: "c", category: "poi_highlight", action: "poi", start: 30, end: 30),
            rawSegment(uuid: "d", category: "interaction", action: "skip", start: 40, end: 45),
            rawSegment(uuid: "e", category: "preview", action: "skip", start: 50, end: 55),
            rawSegment(uuid: "f", category: "filler", action: "skip", start: 60, end: 65),
            rawSegment(uuid: "g", category: "outro", action: "skip", start: 70, end: 75),
        ]
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", body: response(videoID: "v", segments: segments))

        let result = try await SponsorBlockClient(http: http).segments(videoID: "v")

        #expect(result.map(\.category) == [.selfpromo, .musicOfftopic, .poiHighlight, .interaction, .preview, .filler, .outro])
        #expect(result.map(\.actionType) == [.skip, .mute, .poi, .skip, .skip, .skip, .skip])
        let point = try #require(result.first { $0.id == "c" })
        #expect(point.start == 30 && point.end == 30)
    }

    @Test func unknownAndMalformedEntriesAreSkipped() async throws {
        let segments = [
            rawSegment(uuid: "future-category", category: "brand_new_category"),
            rawSegment(uuid: "future-action", action: "teleport"),
            rawSegment(uuid: "backwards", start: 40, end: 30),
            rawSegment(uuid: "negative", start: -3, end: 4),
            #"{"category":"sponsor","actionType":"skip","segment":[1],"UUID":"one-number"}"#,
            #"{"category":"sponsor","actionType":"skip","segment":"1-2","UUID":"not-an-array"}"#,
            #"{"category":"sponsor","actionType":"skip","segment":[1,2]}"#,
            #"{"actionType":"skip","segment":[1,2],"UUID":"no-category"}"#,
            "42",
            rawSegment(uuid: "good", start: 100, end: 110),
        ]
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", body: response(videoID: "v", segments: segments))

        let result = try await SponsorBlockClient(http: http).segments(videoID: "v")

        #expect(result.map(\.id) == ["good"])
    }

    @Test func entriesWithoutASegmentListAreHarmless() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", body: Data(#"[{"videoID":"v"},{"videoID":"v","segments":null},7,{"segments":[]}]"#.utf8))

        #expect(try await SponsorBlockClient(http: http).segments(videoID: "v").isEmpty)
    }

    @Test func serverErrorsAreThrown() async {
        for status in [429, 500, 503] {
            let http = MockHTTPClient()
            http.enqueue("api/skipSegments/", status: status, body: Data("busy".utf8))
            await #expect(throws: NoSlopError.http(status: status)) {
                _ = try await SponsorBlockClient(http: http).segments(videoID: "v")
            }
        }
    }

    @Test func networkFailuresAreThrown() async {
        let http = MockHTTPClient()
        http.enqueueError("api/skipSegments/", NoSlopError.network("offline"))
        await #expect(throws: NoSlopError.network("offline")) {
            _ = try await SponsorBlockClient(http: http).segments(videoID: "v")
        }
    }

    @Test func aResponseThatIsNotAJSONListIsADecodingError() async {
        for body in ["<html>maintenance</html>", #"{"error":"nope"}"#, ""] {
            let http = MockHTTPClient()
            http.enqueue("api/skipSegments/", body: Data(body.utf8))
            await #expect(throws: NoSlopError.self) {
                _ = try await SponsorBlockClient(http: http).segments(videoID: "v")
            }
        }
    }

    @Test func aCustomBaseURLIsUsed() async throws {
        let http = MockHTTPClient()
        http.enqueue("sb.example.com/mirror/api/skipSegments/", status: 404, body: Data())
        let client = SponsorBlockClient(http: http, baseURL: URL(string: "https://sb.example.com/mirror")!)

        _ = try await client.segments(videoID: "dQw4w9WgXcQ")

        #expect(http.requests.first?.url?.absoluteString.hasPrefix("https://sb.example.com/mirror/api/skipSegments/5f6b?") == true)
    }

    // MARK: Caching

    @Test func eachVideoIsCachedForAnHour() async throws {
        let clock = ManualClock()
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", body: response(videoID: "v", segments: [rawSegment(uuid: "x")]))
        let client = SponsorBlockClient(http: http, cacheTTL: 3_600, now: { clock.now })

        let first = try await client.segments(videoID: "v")
        let second = try await client.segments(videoID: "v")
        #expect(first == second)
        #expect(http.requests.count == 1)

        clock.advance(by: 3_599)
        _ = try await client.segments(videoID: "v")
        #expect(http.requests.count == 1)

        clock.advance(by: 2)
        _ = try await client.segments(videoID: "v")
        #expect(http.requests.count == 2)
    }

    @Test func emptyResultsAreCachedToo() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", status: 404, body: Data())
        let client = SponsorBlockClient(http: http)

        _ = try await client.segments(videoID: "v")
        _ = try await client.segments(videoID: "v")
        #expect(http.requests.count == 1)
    }

    @Test func failuresAreNotCached() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", status: 500, body: Data())
        http.enqueue("api/skipSegments/", body: response(videoID: "v", segments: [rawSegment(uuid: "x")]))
        let client = SponsorBlockClient(http: http)

        await #expect(throws: NoSlopError.http(status: 500)) {
            _ = try await client.segments(videoID: "v")
        }
        #expect(try await client.segments(videoID: "v").map(\.id) == ["x"])
        #expect(http.requests.count == 2)
    }

    @Test func lookupsOfTheSameVideoThatOverlapShareOneRequest() async throws {
        let http = SlowHTTPClient(delay: .milliseconds(100), body: response(videoID: "v", segments: [rawSegment(uuid: "x")]))
        let client = SponsorBlockClient(http: http)

        async let first = client.segments(videoID: "v")
        async let second = client.segments(videoID: "v")
        let results = try await [first, second]

        #expect(results[0].map(\.id) == ["x"])
        #expect(results[0] == results[1])
        #expect(http.requestCount == 1)
    }

    @Test func differentVideosAreLookedUpSeparately() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/skipSegments/", body: Data("[]".utf8))
        let client = SponsorBlockClient(http: http)

        _ = try await client.segments(videoID: "one")
        _ = try await client.segments(videoID: "two")
        #expect(http.requests.count == 2)
    }
}
