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

/// One entry of a `title` list as DeArrow sends it.
private func rawTitle(_ title: String, original: Bool = false, votes: Int = 0, locked: Bool = false) -> String {
    let escaped = title
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
    return #"{"title":"\#(escaped)","original":\#(original),"votes":\#(votes),"locked":\#(locked),"UUID":"u"}"#
}

/// The body of `api/branding/<prefix>` with one video in it.
private func branding(_ videoID: String, titles: [String]) -> Data {
    Data(#"{"\#(videoID)":{"titles":[\#(titles.joined(separator: ","))],"thumbnails":[],"randomTime":0.5,"videoDuration":null}}"#.utf8)
}

/// A client that answers every branding request with `body`, and the stub it talks to.
private func makeClient(answering body: Data, status: Int = 200) -> (DeArrowClient, MockHTTPClient) {
    let http = MockHTTPClient()
    http.enqueue("api/branding/", status: status, body: body)
    return (DeArrowClient(http: http), http)
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

@Suite struct DeArrowTests {
    // MARK: From the plan

    @Test func betterTitleForRickroll() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/branding/5f6b", body: try Fixture.data("dearrow_prefix.json"))
        let client = DeArrowClient(http: http)

        let title = await client.betterTitle(videoID: "dQw4w9WgXcQ")

        #expect(title == "Rick Astley - Never gonna give you up (official music video)")
        #expect(title == SampleData.betterTitleForRickroll)
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "sponsor.ajay.app")
        #expect(request.url?.path == "/api/branding/5f6b")
    }

    @Test func titleRules() async {
        // Original titles are never a replacement.
        let (original, _) = makeClient(answering: branding("v", titles: [
            rawTitle("The clickbait original", original: true, votes: 99, locked: true),
        ]))
        #expect(await original.betterTitle(videoID: "v") == nil)

        // A title needs to be locked, or have at least 0 votes.
        let (unvoted, _) = makeClient(answering: branding("v", titles: [rawTitle("Troll", votes: -1)]))
        #expect(await unvoted.betterTitle(videoID: "v") == nil)
        let (locked, _) = makeClient(answering: branding("v", titles: [rawTitle("Troll", votes: -1), rawTitle("Locked", votes: -5, locked: true)]))
        #expect(await locked.betterTitle(videoID: "v") == "Locked")
        let (zero, _) = makeClient(answering: branding("v", titles: [rawTitle("Zero votes", votes: 0)]))
        #expect(await zero.betterTitle(videoID: "v") == "Zero votes")

        // A leading ">" (DeArrow's "do not auto-format" marker) and surrounding whitespace are stripped.
        let (marked, _) = makeClient(answering: branding("v", titles: [rawTitle(">  Spaced out  ")]))
        #expect(await marked.betterTitle(videoID: "v") == "Spaced out")
        let (padded, _) = makeClient(answering: branding("v", titles: [rawTitle("  > Both ways\n")]))
        #expect(await padded.betterTitle(videoID: "v") == "Both ways")
        let (inner, _) = makeClient(answering: branding("v", titles: [rawTitle("a > b")]))
        #expect(await inner.betterTitle(videoID: "v") == "a > b")

        // None at all.
        let (none, _) = makeClient(answering: branding("v", titles: []))
        #expect(await none.betterTitle(videoID: "v") == nil)
    }

    @Test func cachesPerPrefix() async throws {
        let http = MockHTTPClient()
        http.enqueue("api/branding/5f6b", body: try Fixture.data("dearrow_prefix.json"))
        let client = DeArrowClient(http: http)

        // dQw4w9WgXcQ and 1H8_tk_dMLw share the prefix 5f6b.
        #expect(await client.betterTitle(videoID: "dQw4w9WgXcQ") != nil)
        _ = await client.betterTitle(videoID: "1H8_tk_dMLw")
        _ = await client.betterTitle(videoID: "dQw4w9WgXcQ")
        #expect(http.requests.count == 1)

        // Another prefix is another request.
        let other = "aqz-KE-bpKQ"
        #expect(HashPrefix.sha256Prefix(other) != "5f6b")
        http.enqueue("api/branding/\(HashPrefix.sha256Prefix(other))", status: 404, body: Data())
        _ = await client.betterTitle(videoID: other)
        #expect(http.requests.count == 2)
    }

    // MARK: More rules

    @Test func theFirstUsableTitleWins() async {
        let (client, _) = makeClient(answering: branding("v", titles: [
            rawTitle("Original", original: true),
            rawTitle("Unwanted", votes: -3),
            rawTitle("First good", votes: 4),
            rawTitle("Second good", votes: 9, locked: true),
        ]))
        #expect(await client.betterTitle(videoID: "v") == "First good")
    }

    @Test func titlesThatAreEmptyAfterCleaningAreSkipped() async {
        let (client, _) = makeClient(answering: branding("v", titles: [rawTitle(">"), rawTitle("   "), rawTitle("Real one")]))
        #expect(await client.betterTitle(videoID: "v") == "Real one")

        let (onlyEmpty, _) = makeClient(answering: branding("v", titles: [rawTitle(">   ")]))
        #expect(await onlyEmpty.betterTitle(videoID: "v") == nil)
    }

    @Test func missingFieldsAreHandledSafely() async {
        // No votes and not locked: nothing vouches for the title.
        let (unknownVotes, _) = makeClient(answering: Data(#"{"v":{"titles":[{"title":"No votes","original":false}]}}"#.utf8))
        #expect(await unknownVotes.betterTitle(videoID: "v") == nil)

        // No "original" flag: a title that is not marked as the original is used.
        let (noFlag, _) = makeClient(answering: Data(#"{"v":{"titles":[{"title":"No flag","votes":2}]}}"#.utf8))
        #expect(await noFlag.betterTitle(videoID: "v") == "No flag")

        // Entries without a title, and a "titles" that is not a list.
        let (broken, _) = makeClient(answering: Data(#"{"v":{"titles":[{"votes":3},{"title":5,"votes":3},"text",null,{"title":"Fine","votes":1}]}}"#.utf8))
        #expect(await broken.betterTitle(videoID: "v") == "Fine")
        let (notAList, _) = makeClient(answering: Data(#"{"v":{"titles":"nope"}}"#.utf8))
        #expect(await notAList.betterTitle(videoID: "v") == nil)
    }

    @Test func otherVideosInTheResponseDoNotMatter() async {
        let body = Data(#"{"other":{"titles":[{"title":"Not mine","original":false,"votes":9,"locked":true}]}}"#.utf8)
        let (client, _) = makeClient(answering: body)
        #expect(await client.betterTitle(videoID: "v") == nil)
    }

    // MARK: Failures

    @Test func failuresGiveNoTitle() async {
        let (notFound, _) = makeClient(answering: Data("Not Found".utf8), status: 404)
        #expect(await notFound.betterTitle(videoID: "v") == nil)
        let (serverError, _) = makeClient(answering: Data("oops".utf8), status: 500)
        #expect(await serverError.betterTitle(videoID: "v") == nil)
        let (garbage, _) = makeClient(answering: Data("<html>".utf8))
        #expect(await garbage.betterTitle(videoID: "v") == nil)
        let (list, _) = makeClient(answering: Data("[]".utf8))
        #expect(await list.betterTitle(videoID: "v") == nil)

        let http = MockHTTPClient()
        http.enqueueError("api/branding/", NoSlopError.network("offline"))
        #expect(await DeArrowClient(http: http).betterTitle(videoID: "v") == nil)
    }

    @Test func aFailedLookupIsTriedAgainNextTime() async {
        let http = MockHTTPClient()
        http.enqueueError("api/branding/", NoSlopError.network("offline"))
        http.enqueue("api/branding/", body: branding("v", titles: [rawTitle("Back online")]))
        let client = DeArrowClient(http: http)

        #expect(await client.betterTitle(videoID: "v") == nil)
        #expect(await client.betterTitle(videoID: "v") == "Back online")
        #expect(http.requests.count == 2)
    }

    @Test func lookupsThatOverlapAndShareAPrefixShareOneRequest() async {
        // dQw4w9WgXcQ and 1H8_tk_dMLw share the prefix 5f6b.
        let http = SlowHTTPClient(delay: .milliseconds(100), body: branding("dQw4w9WgXcQ", titles: [rawTitle("Shared")]))
        let client = DeArrowClient(http: http)

        async let first = client.betterTitle(videoID: "dQw4w9WgXcQ")
        async let second = client.betterTitle(videoID: "1H8_tk_dMLw")
        async let third = client.betterTitle(videoID: "dQw4w9WgXcQ")
        let titles = await [first, second, third]

        #expect(titles == ["Shared", nil, "Shared"])
        #expect(http.requestCount == 1)
    }

    @Test func aMissingPrefixIsCachedAsEmpty() async {
        let http = MockHTTPClient()
        http.enqueue("api/branding/", status: 404, body: Data())
        let client = DeArrowClient(http: http)

        #expect(await client.betterTitle(videoID: "v") == nil)
        #expect(await client.betterTitle(videoID: "v") == nil)
        #expect(http.requests.count == 1)
    }

    @Test func theCacheExpiresAfterAnHour() async {
        let clock = ManualClock()
        let http = MockHTTPClient()
        http.enqueue("api/branding/", body: branding("v", titles: [rawTitle("Cached")]))
        let client = DeArrowClient(http: http, cacheTTL: 3_600, now: { clock.now })

        #expect(await client.betterTitle(videoID: "v") == "Cached")
        clock.advance(by: 3_599)
        #expect(await client.betterTitle(videoID: "v") == "Cached")
        #expect(http.requests.count == 1)

        clock.advance(by: 2)
        #expect(await client.betterTitle(videoID: "v") == "Cached")
        #expect(http.requests.count == 2)
    }

    @Test func aCustomBaseURLIsUsed() async {
        let http = MockHTTPClient()
        http.enqueue("dearrow.example.com/api/branding/", body: branding("v", titles: [rawTitle("Mirror")]))
        let client = DeArrowClient(http: http, baseURL: URL(string: "https://dearrow.example.com")!)

        #expect(await client.betterTitle(videoID: "v") == "Mirror")
    }
}
