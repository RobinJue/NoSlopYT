import Foundation
import Testing
@testable import NoSlopKit

@Suite struct PlaylistParserTests {
    private static let playlistID = "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B"

    // MARK: From the plan

    @Test func playlistPage() throws {
        let p = try #require(PlaylistParser.parse(try Fixture.json("playlist_sample.json"), playlistID: Self.playlistID))
        #expect(p.info.id == "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        #expect(p.info.title == "Blender for Complete Beginners Tutorial Series")
        #expect(p.videos.items.count == 14)
        let first = try #require(p.videos.items.first)
        #expect(first.id == "sgMfEq3pDE0")
        #expect(first.title == "Part 1 - Blender for Complete Beginners Tutorial Series (Navigation & Shortcut Keys)")
        #expect(p.videos.continuation != nil)   // from continuationItemViewModel
    }

    // MARK: Header

    @Test func headerDetails() throws {
        let p = try #require(PlaylistParser.parse(try Fixture.json("playlist_sample.json"), playlistID: Self.playlistID))
        #expect(p.info.videoCount == 14)
        #expect(p.info.videoCountText == "14 videos")
        #expect(p.description == "In this Blender for complete beginners tutorial series you will learn the basics of Blender while creating a snowman character.")
        #expect(!p.info.thumbnails.isEmpty)
        #expect(p.info.thumbnails.map(\.width) == p.info.thumbnails.map(\.width).sorted { ($0 ?? 0) < ($1 ?? 0) })
        #expect(p.info.thumbnails.allSatisfy { $0.url.host?.hasSuffix("ytimg.com") == true })
        let owner = try #require(p.info.channel)
        #expect(owner.name == "Ryan King Art")
        #expect(owner.id == "UCIXjev1_mJ1plJhF9lGarQg")
        #expect(owner.handle == "@RyanKingArt")
        #expect(owner.avatarURL != nil)
    }

    @Test func videoDetails() throws {
        let p = try #require(PlaylistParser.parse(try Fixture.json("playlist_sample.json"), playlistID: Self.playlistID))
        let first = try #require(p.videos.items.first)
        #expect(first.durationSeconds == 1946)   // 32:26
        #expect(first.viewCount == 296_000)
        #expect(first.viewCountText == "296K views")
        #expect(first.publishedText == "2 years ago")
        #expect(first.channel?.name == "Ryan King Art")
        #expect(first.channel?.id == "UCIXjev1_mJ1plJhF9lGarQg")
        #expect(first.thumbnails.map(\.width) == [168, 196, 246, 336])
        #expect(!first.isShort && !first.isLive)
        #expect(p.videos.items.map(\.id) == [
            "sgMfEq3pDE0", "Wh4GGEUiNAE", "6vQq9yS3Np8", "KrM7Wh32lEM", "IGf7Ex5Ig_I", "0bNtSUm1GUg", "bR6q6rpXCKQ",
            "KJUWhT8iwtk", "7PjIiYs93hU", "mDRr7n6Bejw", "1j-q4jJYv6Q", "eT-s5W_7jvw", "JDGX9wwPt8Q", "J5dIOfaZdYE",
        ])
    }

    @Test func continuationTokenIsTheViewModelsOwn() throws {
        let json = try Fixture.json("playlist_sample.json")
        let p = try #require(PlaylistParser.parse(json, playlistID: Self.playlistID))
        let expected = try #require(json["contents"]?["twoColumnBrowseResultsRenderer"]?["tabs"]?[0]?["tabRenderer"]?["content"]?["sectionListRenderer"]?["contents"]?[1]?["continuationItemViewModel"]?["continuationCommand"]?["innertubeCommand"]?["continuationCommand"]?["token"]?.string)
        #expect(p.videos.continuation == expected)
    }

    @Test func infoIdIsTheRequestedId() throws {
        // The response does not repeat the id in a place we read; the caller's id is authoritative.
        let p = try #require(PlaylistParser.parse(try Fixture.json("playlist_sample.json"), playlistID: "PLother"))
        #expect(p.info.id == "PLother")
    }

    // MARK: Continuation

    /// 14 lockups plus a trailing continuation item, the way `browse` answers a playlist continuation.
    private func continuationResponse(token: String?) throws -> JSON {
        let json = try Fixture.json("playlist_sample.json")
        let section = try #require(json["contents"]?["twoColumnBrowseResultsRenderer"]?["tabs"]?[0]?["tabRenderer"]?["content"]?["sectionListRenderer"]?["contents"])
        var items = try #require(section[0]?["itemSectionRenderer"]?["contents"]?.array)
        if let token {
            items.append(["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": .string(token)]]]])
        }
        return [
            "onResponseReceivedActions": [[
                "clickTrackingParams": "abc",
                "appendContinuationItemsAction": ["continuationItems": .array(items), "targetId": "PLAYLIST_VIDEO_LIST_ID"],
            ]],
        ]
    }

    @Test func continuationPage() throws {
        let p = PlaylistParser.parseContinuation(try continuationResponse(token: "NEXT"))
        #expect(p.items.count == 14)
        #expect(p.items.first?.id == "sgMfEq3pDE0")
        #expect(p.continuation == "NEXT")
    }

    @Test func lastContinuationPageHasNoToken() throws {
        let p = PlaylistParser.parseContinuation(try continuationResponse(token: nil))
        #expect(p.items.count == 14)
        #expect(p.continuation == nil)
    }

    @Test func continuationOfAFirstPageIsEmpty() throws {
        let p = PlaylistParser.parseContinuation(try Fixture.json("playlist_sample.json"))
        #expect(p.items.isEmpty)
        #expect(p.continuation == nil)
    }

    // MARK: Missing pieces

    @Test func videosSurviveWithoutAHeader() throws {
        var json = try Fixture.json("playlist_sample.json")
        for key in ["header", "metadata", "microformat", "sidebar"] {
            json = BrowseJSONEdit.removingDirectKey(key, in: json)
        }
        let p = try #require(PlaylistParser.parse(json, playlistID: Self.playlistID))
        #expect(p.videos.items.count == 14)
        #expect(p.info.id == Self.playlistID)
        #expect(p.info.channel == nil)
    }

    @Test func ownerAndCountFallBackToTheHeaderWithoutTheSidebar() throws {
        let json = BrowseJSONEdit.removingDirectKey("sidebar", in: try Fixture.json("playlist_sample.json"))
        let p = try #require(PlaylistParser.parse(json, playlistID: Self.playlistID))
        // The header's avatar stack says "by Ryan King Art" and links to the channel.
        let owner = try #require(p.info.channel)
        #expect(owner.name == "Ryan King Art")
        #expect(owner.id == "UCIXjev1_mJ1plJhF9lGarQg")
        #expect(owner.handle == "@RyanKingArt")
        #expect(owner.avatarURL?.absoluteString.contains("=s48-") == true)
        #expect(p.info.videoCount == 14)
        #expect(p.info.title == "Blender for Complete Beginners Tutorial Series")
    }

    @Test func countFallsBackToTheSidebarStats() throws {
        // Without the header, the old sidebar still says "14 videos".
        let json = BrowseJSONEdit.removingDirectKey("header", in: try Fixture.json("playlist_sample.json"))
        let p = try #require(PlaylistParser.parse(json, playlistID: Self.playlistID))
        #expect(p.info.videoCountText == "14 videos")
        #expect(p.info.videoCount == 14)
        #expect(p.info.channel?.name == "Ryan King Art")
        #expect(p.info.title == "Blender for Complete Beginners Tutorial Series")
    }

    @Test func titleFallsBackToTheMetadata() throws {
        var json = try Fixture.json("playlist_sample.json")
        for key in ["header", "sidebar"] {
            json = BrowseJSONEdit.removingDirectKey(key, in: json)
        }
        let p = try #require(PlaylistParser.parse(json, playlistID: Self.playlistID))
        #expect(p.info.title == "Blender for Complete Beginners Tutorial Series")
        #expect(p.description?.hasPrefix("In this Blender for complete beginners") == true)
        #expect(!p.info.thumbnails.isEmpty)   // microformat thumbnail
    }

    @Test func nothingParseableIsNil() throws {
        #expect(PlaylistParser.parse([:], playlistID: Self.playlistID) == nil)
        #expect(PlaylistParser.parse([], playlistID: Self.playlistID) == nil)
        // A playlist that does not exist answers with an alert and nothing else.
        let alert: JSON = ["alerts": [["alertRenderer": ["type": "ERROR", "text": ["runs": [["text": "The playlist does not exist."]]]]]]]
        #expect(PlaylistParser.parse(alert, playlistID: Self.playlistID) == nil)
    }
}
