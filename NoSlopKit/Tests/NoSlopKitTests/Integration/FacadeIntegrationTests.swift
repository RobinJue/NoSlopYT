import Foundation
import Testing
@testable import NoSlopKit

/// The InnerTube facade with the real parsers, fed with the responses captured from YouTube on 2026-11-03 through a
/// scripted HTTP client: what the app gets when YouTube answers the way it did then. The request shapes are pinned in
/// `FacadeRequestTests` and the parsers have tests of their own; these tests show that the pieces fit together, from
/// the request the facade builds to the model the screens receive, and that the continuation tokens the parsers read
/// are the ones the facade sends back.
@Suite struct FacadeIntegrationTests {
    private let http: MockHTTPClient
    private let service: InnerTubeYouTubeService

    init() throws {
        let http = MockHTTPClient()
        // The visitorData every InnerTube request needs, from the captured sw.js_data.
        http.enqueue("sw.js_data", body: try Fixture.data("sw_js_data.txt"))
        let client = InnerTubeClient(http: http, config: InnerTubeConfig(hl: "en", gl: "US"), visitorStore: InMemoryVisitorDataStore())
        self.http = http
        self.service = InnerTubeYouTubeService(client: client, http: http)
    }

    /// Queues `fixture` as the answer of the next request to `endpoint` ("search", "next", "browse").
    private func answer(_ endpoint: String, with fixture: String) throws {
        http.enqueue("youtubei/v1/\(endpoint)", body: try Fixture.data(fixture))
    }

    /// The JSON bodies sent to `endpoint`, in order.
    private func bodies(sentTo endpoint: String) -> [JSON] {
        http.requests
            .filter { $0.url?.path == "/youtubei/v1/\(endpoint)" }
            .compactMap { http.bodyJSON(of: $0) }
    }

    // MARK: From the plan (Task 11, Step 2)

    @Test func searchThroughFacade() async throws {
        try answer("search", with: "search_blender_tutorial.json")

        let page = try await service.search(query: "blender tutorial", filter: SearchFilter())

        #expect(page.items.count == 24)
        let videos = page.items.compactMap(\.video)
        let first = try #require(videos.first { !$0.isShort })
        #expect(first.id == "z-Xl9tGqH14")
        #expect(first.title == "Beginner Blender Tutorial (2026)")
        #expect(first.viewCount == 2_763_792)
        // 16 regular videos and 6 Shorts (five from the shelf, and qAJZC5kOpOE, which is a Short in a videoRenderer).
        #expect(videos.filter { !$0.isShort }.count == 16)
        #expect(videos.filter(\.isShort).count == 6)
        #expect(page.continuation != nil)

        let sent = bodies(sentTo: "search")
        #expect(sent.count == 1)
        #expect(sent.first?["query"]?.string == "blender tutorial")
    }

    @Test func videoDetailsThroughFacade() async throws {
        try answer("next", with: "next_aqz.json")

        let details = try await service.videoDetails(id: "aqz-KE-bpKQ")

        #expect(details.id == "aqz-KE-bpKQ")
        #expect(details.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(details.channel.name == "Blender")
        #expect(details.viewCount == 23_500_582)
        #expect(details.related.count == 26)
        #expect(details.related.filter(\.isShort).count == 6)
        #expect(details.related.first?.id == "7pPUE6cGFwI")
        #expect(details.relatedContinuation != nil)
        #expect(details.commentsContinuation != nil)

        #expect(bodies(sentTo: "next").first?["videoId"]?.string == "aqz-KE-bpKQ")
    }

    @Test func channelThroughFacade() async throws {
        try answer("browse", with: "channel_blender_videos.json")

        let page = try await service.channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")

        #expect(page.header.id == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(page.header.name == "Blender")
        #expect(page.header.handle == "@BlenderOfficial")
        #expect(page.availableTabs == [.videos, .live, .playlists])
        #expect(page.videos.items.count == 30)
        #expect(page.videos.items.first?.video?.id == "mHrHLqQj7Ts")
        #expect(page.videos.continuation != nil)

        let sent = try #require(bodies(sentTo: "browse").first)
        #expect(sent["browseId"]?.string == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(sent["params"]?.string == ChannelParser.tabParams[.videos])
    }

    @Test func playlistThroughFacade() async throws {
        try answer("browse", with: "playlist_sample.json")

        let page = try await service.playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")

        #expect(page.info.id == "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        #expect(page.info.title == "Blender for Complete Beginners Tutorial Series")
        #expect(page.videos.items.count == 14)
        #expect(page.videos.items.first?.id == "sgMfEq3pDE0")
        #expect(page.videos.continuation != nil)

        #expect(bodies(sentTo: "browse").first?["browseId"]?.string == "VLPLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
    }

    @Test func commentsThroughFacade() async throws {
        try answer("next", with: "comments_aqz.json")

        let page = try await service.comments(continuation: "COMMENTS-TOKEN")

        #expect(page.comments.count == 20)
        #expect(page.totalCountText == "5,222 Comments")
        #expect(page.comments.first?.id == "UgxNivqkidvk9k_eR_B4AaABAg")
        #expect(page.continuation != nil)

        #expect(bodies(sentTo: "next").first?["continuation"]?.string == "COMMENTS-TOKEN")
    }

    // MARK: The tokens the parsers read are the ones the facade sends back

    @Test func searchPagesChainThroughTheirContinuation() async throws {
        try answer("search", with: "search_blender_tutorial.json")
        try answer("search", with: "search_blender_tutorial_cont.json")

        let first = try await service.search(query: "blender tutorial", filter: SearchFilter())
        let token = try #require(first.continuation)
        let second = try await service.searchMore(continuation: token)

        #expect(second.items.compactMap(\.video).count == 19)
        #expect(second.continuation != nil)
        #expect(second.continuation != token)
        let sent = bodies(sentTo: "search")
        #expect(sent.count == 2)
        #expect(sent.last?["continuation"]?.string == token)
        #expect(sent.last?["query"] == nil)
    }

    @Test func relatedVideosAndCommentsChainThroughTheTokensOfTheWatchPage() async throws {
        try answer("next", with: "next_aqz.json")
        try answer("next", with: "next_aqz_related_cont.json")
        try answer("next", with: "comments_aqz.json")
        try answer("next", with: "comments_aqz_cont.json")

        let details = try await service.videoDetails(id: "aqz-KE-bpKQ")
        let relatedToken = try #require(details.relatedContinuation)
        let commentsToken = try #require(details.commentsContinuation)

        let moreRelated = try await service.moreRelated(continuation: relatedToken)
        #expect(moreRelated.items.count == 20)
        #expect(moreRelated.continuation != nil)

        let comments = try await service.comments(continuation: commentsToken)
        #expect(comments.comments.count == 20)
        let nextComments = try await service.comments(continuation: try #require(comments.continuation))
        #expect(nextComments.comments.count == 20)
        #expect(Set(nextComments.comments.map(\.id)).isDisjoint(with: comments.comments.map(\.id)), "the second page continues the first")

        let sent = bodies(sentTo: "next")
        #expect(sent.count == 4)
        #expect(sent[1]["continuation"]?.string == relatedToken)
        #expect(sent[2]["continuation"]?.string == commentsToken)
        #expect(sent[3]["continuation"]?.string == comments.continuation)
    }

    @Test func aPageYouTubeAnswersWithGarbageIsAnEmptyPageNotAnError() async throws {
        // Robustness rule: nothing parseable is an empty page. Only a watch page, channel or playlist without a header
        // cannot be empty.
        try answer("search", with: "player_visionos_rickroll.json")
        let page = try await service.search(query: "blender", filter: SearchFilter())
        #expect(page.items.isEmpty)
        #expect(page.continuation == nil)

        try answer("browse", with: "resolve_handle.json")
        await #expect(throws: NoSlopError.self) { _ = try await service.channel(id: "UCSMOQeBJ2RAnuFungnQOxLg") }
    }
}
