import Foundation
import Testing
@testable import NoSlopKit

@Suite struct ResolveURLTests {
    // MARK: From the plan

    @Test func resolveHandle() throws {
        #expect(ResolveURLParser.parse(try Fixture.json("resolve_handle.json")) == .channel(id: "UCSMOQeBJ2RAnuFungnQOxLg"))
    }

    // MARK: Other endpoints

    @Test func aWatchEndpointIsAVideo() {
        let json: JSON = ["endpoint": ["watchEndpoint": ["videoId": "dQw4w9WgXcQ"]]]
        #expect(ResolveURLParser.parse(json) == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
    }

    @Test func aWatchEndpointKeepsItsStartTime() {
        let json: JSON = ["endpoint": ["watchEndpoint": ["videoId": "dQw4w9WgXcQ", "startTimeSeconds": 42]]]
        #expect(ResolveURLParser.parse(json) == .video(id: "dQw4w9WgXcQ", startSeconds: 42))
    }

    @Test func aPlaylistBrowseIdLosesItsVLPrefix() {
        let json: JSON = ["endpoint": ["browseEndpoint": ["browseId": "VLPLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"]]]
        #expect(ResolveURLParser.parse(json) == .playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"))
    }

    @Test func aChannelBrowseIdIsAChannel() {
        let json: JSON = ["endpoint": ["browseEndpoint": ["browseId": "UCOKHwx1VCdgnxwbjyb9Iu1g", "params": "EgC4AQCSAwDyBgQKAjIA"]]]
        #expect(ResolveURLParser.parse(json) == .channel(id: "UCOKHwx1VCdgnxwbjyb9Iu1g"))
    }

    @Test func theEndpointMayBeAtTheTopLevel() {
        // Defensive: if YouTube ever drops the wrapper, the same endpoint objects still work.
        #expect(ResolveURLParser.parse(["browseEndpoint": ["browseId": "UCSMOQeBJ2RAnuFungnQOxLg"]]) == .channel(id: "UCSMOQeBJ2RAnuFungnQOxLg"))
    }

    @Test func aVideoWinsOverAPlaylistInTheSameLink() {
        // /watch?v=…&list=… resolves to a watchEndpoint that also names the playlist.
        let json: JSON = ["endpoint": ["watchEndpoint": ["videoId": "dQw4w9WgXcQ", "playlistId": "PLx"]]]
        #expect(ResolveURLParser.parse(json) == .video(id: "dQw4w9WgXcQ", startSeconds: nil))
    }

    // MARK: Unknown shapes

    @Test(arguments: [
        "{}",
        "[]",
        "null",
        #"{"endpoint":{}}"#,
        #"{"endpoint":{"urlEndpoint":{"url":"https://example.com"}}}"#,
        #"{"endpoint":{"browseEndpoint":{"browseId":"FEwhat_to_watch"}}}"#,
        #"{"endpoint":{"browseEndpoint":{"browseId":"FEhashtag","params":"x"}}}"#,
        #"{"endpoint":{"browseEndpoint":{}}}"#,
        #"{"endpoint":{"browseEndpoint":{"browseId":"VL"}}}"#,
        #"{"endpoint":{"browseEndpoint":{"browseId":""}}}"#,
        #"{"endpoint":{"watchEndpoint":{}}}"#,
        #"{"endpoint":{"watchEndpoint":{"videoId":""}}}"#,
        #"{"endpoint":"unexpected"}"#,
        #"{"responseContext":{"visitorData":"x"}}"#,
    ])
    func unknownShapesGiveNil(text: String) throws {
        let json = try JSON(data: Data(text.utf8))
        #expect(ResolveURLParser.parse(json) == nil)
    }
}
