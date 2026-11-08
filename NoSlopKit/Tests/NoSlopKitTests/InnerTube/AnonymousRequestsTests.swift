import Foundation
import Testing
@testable import NoSlopKit

/// Anonymous traffic must stay anonymous: nothing of the optional TV connection reaches it.
@Suite struct AnonymousRequestsTests {
    @Test func anonymousRequestsCarryNoAuthorizationOrCookies() async throws {
        let http = MockHTTPClient()
        http.enqueue("sw.js_data", status: 404, body: Data())
        http.enqueue("youtubei/v1/visitor_id", body: Data(#"{"responseContext":{"visitorData":"CgSyntheticVisitorData0001"}}"#.utf8))
        http.enqueue("youtubei/v1/browse", body: Data("{}".utf8))
        let client = InnerTubeClient(http: http, config: InnerTubeConfig(hl: "en", gl: "US"), visitorStore: InMemoryVisitorDataStore())
        _ = try await client.post(endpoint: "browse", profile: .web, body: ["browseId": "FEwhat_to_watch"])

        #expect(http.requests.count >= 2)
        for request in http.requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.allHTTPHeaderFields?.keys.contains { $0.lowercased() == "authorization" || $0.lowercased() == "cookie" } != true)
        }
    }
}
