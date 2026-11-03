import Foundation
import Testing
@testable import NoSlopKit

/// The test double itself needs to be trustworthy: every later task builds on its exact matching rules.
private func mockRequest(_ url: String, method: String = "GET", body: Data? = nil) -> URLRequest {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    request.httpBody = body
    return request
}

private func bodyText(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

@Suite struct MockHTTPClientTests {
    @Test func answersWithTheQueuedStatusBodyAndHeaders() async throws {
        let http = MockHTTPClient()
        http.enqueue("example.com/a", status: 206, body: Data("hello".utf8), headers: ["Content-Range": "bytes 0-4/5"])
        let (data, response) = try await http.send(mockRequest("https://example.com/a?x=1"))
        #expect(bodyText(data) == "hello")
        #expect(response.statusCode == 206)
        #expect(response.value(forHTTPHeaderField: "Content-Range") == "bytes 0-4/5")
        #expect(response.url?.absoluteString == "https://example.com/a?x=1")
    }

    @Test func statusDefaultsTo200() async throws {
        let http = MockHTTPClient()
        http.enqueue("ok", body: Data())
        let (_, response) = try await http.send(mockRequest("https://example.com/ok"))
        #expect(response.statusCode == 200)
    }

    @Test func unmatchedRequestsThrowNotFoundAndAreStillRecorded() async {
        let http = MockHTTPClient()
        http.enqueue("queued-path", body: Data())
        await #expect(throws: NoSlopError.http(status: 404)) {
            _ = try await http.send(mockRequest("https://example.com/something-else"))
        }
        #expect(http.requests.count == 1)
        #expect(http.requests.first?.url?.absoluteString == "https://example.com/something-else")
    }

    @Test func httpErrorStatusesAreReturnedNotThrown() async throws {
        let http = MockHTTPClient()
        http.enqueue("fail", status: 500, body: Data("boom".utf8))
        let (data, response) = try await http.send(mockRequest("https://example.com/fail"))
        #expect(response.statusCode == 500)
        #expect(bodyText(data) == "boom")
    }

    @Test func sameMatchIsServedFirstInFirstOutAndTheLastOneIsReused() async throws {
        let http = MockHTTPClient()
        http.enqueue("player", body: Data("bot".utf8))
        http.enqueue("player", body: Data("ok".utf8))
        var served: [String] = []
        for _ in 0..<4 {
            served.append(bodyText(try await http.send(mockRequest("https://x/youtubei/v1/player")).0))
        }
        #expect(served == ["bot", "ok", "ok", "ok"])
    }

    @Test func differentMatchesInterleaveInArrivalOrder() async throws {
        // The shape of "sw.js_data(vd1) -> player(bot) -> sw.js_data(vd2) -> player(OK)".
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", body: Data("vd1".utf8))
        http.enqueue("v1/player", body: Data("bot".utf8))
        http.enqueue("sw.js_data", body: Data("vd2".utf8))
        http.enqueue("v1/player", body: Data("OK".utf8))

        let first = try await http.send(mockRequest("https://x/sw.js_data")).0
        let second = try await http.send(mockRequest("https://x/youtubei/v1/player?prettyPrint=false")).0
        let third = try await http.send(mockRequest("https://x/sw.js_data")).0
        let fourth = try await http.send(mockRequest("https://x/youtubei/v1/player?prettyPrint=false")).0
        #expect([first, second, third, fourth].map(bodyText) == ["vd1", "bot", "vd2", "OK"])
        #expect(http.requests.count == 4)
    }

    @Test func theFirstQueuedMatchingEntryWins() async throws {
        let http = MockHTTPClient()
        http.enqueue("youtubei", body: Data("generic".utf8))
        http.enqueue("youtubei/v1/player", body: Data("specific".utf8))
        #expect(bodyText(try await http.send(mockRequest("https://x/youtubei/v1/player")).0) == "generic")
    }

    @Test func queuedErrorsAreThrownInOrder() async throws {
        struct Boom: Error, Equatable {}
        let http = MockHTTPClient()
        http.enqueueError("flaky", Boom())
        http.enqueue("flaky", body: Data("recovered".utf8))
        await #expect(throws: Boom()) {
            _ = try await http.send(mockRequest("https://x/flaky"))
        }
        #expect(bodyText(try await http.send(mockRequest("https://x/flaky")).0) == "recovered")
        #expect(http.requests.count == 2)
    }

    @Test func aLoneErrorIsReusedLikeAnyOtherReply() async {
        let http = MockHTTPClient()
        http.enqueueError("offline", NoSlopError.network("offline"))
        for _ in 0..<3 {
            await #expect(throws: NoSlopError.network("offline")) {
                _ = try await http.send(mockRequest("https://x/offline"))
            }
        }
        #expect(http.requests.count == 3)
    }

    @Test func recordsRequestsWithMethodHeadersAndBody() async throws {
        let http = MockHTTPClient()
        http.enqueue("post", body: Data())
        var post = mockRequest("https://x/post", method: "POST", body: Data(#"{"videoId":"aqz-KE-bpKQ","n":[1,2]}"#.utf8))
        post.setValue("101", forHTTPHeaderField: "X-YouTube-Client-Name")
        _ = try await http.send(post)

        let recorded = try #require(http.requests.first)
        #expect(recorded.httpMethod == "POST")
        #expect(recorded.value(forHTTPHeaderField: "X-YouTube-Client-Name") == "101")
        let body = try #require(http.bodyJSON(of: recorded))
        #expect(body["videoId"]?.string == "aqz-KE-bpKQ")
        #expect(body["n"]?[1]?.int == 2)
    }

    @Test func bodyJSONIsNilWithoutAJSONBody() {
        let http = MockHTTPClient()
        #expect(http.bodyJSON(of: mockRequest("https://x/get")) == nil)
        #expect(http.bodyJSON(of: mockRequest("https://x/post", method: "POST", body: Data())) == nil)
        #expect(http.bodyJSON(of: mockRequest("https://x/post", method: "POST", body: Data("not json".utf8))) == nil)
    }

    @Test func isSafeToUseFromManyTasksAtOnce() async throws {
        let http = MockHTTPClient()
        http.enqueue("ping", body: Data("pong".utf8))
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<50 {
                group.addTask {
                    bodyText(try await http.send(mockRequest("https://x/ping?n=\(index)")).0)
                }
            }
            for try await answer in group {
                #expect(answer == "pong")
            }
        }
        #expect(http.requests.count == 50)
    }

    @Test func fixturesCanBeServedAsBodies() async throws {
        let http = MockHTTPClient()
        http.enqueue("visitor_id", body: try Fixture.data("visitor_id.json"))
        let (data, _) = try await http.send(mockRequest("https://x/youtubei/v1/visitor_id"))
        let json = try JSON(data: data)
        #expect(json["responseContext"]?["visitorData"]?.string?.hasPrefix("Cg") == true)
    }
}
