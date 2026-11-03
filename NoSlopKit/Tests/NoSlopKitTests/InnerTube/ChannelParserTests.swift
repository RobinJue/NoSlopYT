import Foundation
import Testing
@testable import NoSlopKit

@Suite struct ChannelParserTests {
    // MARK: From the plan

    @Test func tabParams() {
        #expect(ChannelParser.tabParams == [
            .videos: "EgZ2aWRlb3PyBgQKAjoA",
            .live: "EgdzdHJlYW1z8gYECgJ6AA%3D%3D",
            .playlists: "EglwbGF5bGlzdHPyBgoKCEIGCgIQaCIA",
        ])
    }

    @Test func channelVideosTab() throws {
        let json = try Fixture.json("channel_blender_videos.json")
        let page = try #require(ChannelParser.parseChannelPage(json))
        #expect(page.header.id == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(page.header.name == "Blender")
        #expect(page.header.handle == "@BlenderOfficial")
        #expect(page.header.subscriberCountText == "1.25M subscribers")
        #expect(page.header.videoCountText == "1.5K videos")
        #expect(page.header.avatarURL != nil)
        #expect(page.header.bannerURL != nil)
        #expect(page.availableTabs == [.videos, .live, .playlists])
        #expect(page.videos.items.count == 30)
        let v = try #require(page.videos.items.first?.video)
        #expect(v.id == "mHrHLqQj7Ts")
        #expect(v.title == "Making of: The Blender Open Movies Exhibition")
        #expect(v.durationSeconds == 280)
        #expect(page.videos.continuation != nil)

        // The grid's continuation, not the last continuationCommand of the document (which belongs to the
        // "about" panel inside the header).
        let gridToken = try #require(json["contents"]?["twoColumnBrowseResultsRenderer"]?["tabs"]?[1]?["tabRenderer"]?["content"]?["richGridRenderer"]?["contents"]?[30]?["continuationItemRenderer"]?["continuationEndpoint"]?["continuationCommand"]?["token"]?.string)
        let aboutToken = try #require(json.findAll("token").last?.string)
        #expect(gridToken != aboutToken)
        #expect(page.videos.continuation == gridToken)
    }

    @Test func channelShortsTabAllShort() throws {
        let p = ChannelParser.parseTab(try Fixture.json("channel_blender_shorts.json"))
        #expect(p.items.count == 35)
        #expect(p.items.allSatisfy { $0.video?.isShort == true })
        let first = try #require(p.items.first?.video)
        #expect(first.id == "YsKxkP_kGbE")
        #expect(first.title == "Default Cube: the Interview")
        #expect(first.viewCountText == "21K views")
        #expect(p.items.last?.video?.id == "PnBOcf7sMMI")
        #expect(p.continuation == nil)   // the last page: no continuation item at the end of the grid
    }

    @Test func channelPlaylistsTab() throws {
        let p = ChannelParser.parseTab(try Fixture.json("channel_blender_playlists.json"))
        #expect(p.items.count == 30)
        guard case .playlist(let pl)? = p.items.first else {
            Issue.record("expected playlist")
            return
        }
        #expect(pl.id == "PLa1F2ddGya_-I9y1nXALrBqrZNdlUE012")
        #expect(pl.title == "Blender Conference 2026")
        #expect(pl.videoCount == 95)
        #expect(pl.videoCountText == "95 videos")
        #expect(!pl.thumbnails.isEmpty)
        #expect(p.continuation != nil)
    }

    @Test func channelLiveTab() throws {
        #expect(ChannelParser.parseTab(try Fixture.json("channel_blender_live.json")).items.count == 30)
    }

    @Test func tabContinuationTokensAreTheGridsOwn() throws {
        let live = try Fixture.json("channel_blender_live.json")
        let liveToken = try #require(live["contents"]?["twoColumnBrowseResultsRenderer"]?["tabs"]?[3]?["tabRenderer"]?["content"]?["richGridRenderer"]?["contents"]?[30]?["continuationItemRenderer"]?["continuationEndpoint"]?["continuationCommand"]?["token"]?.string)
        #expect(ChannelParser.parseTab(live).continuation == liveToken)
        #expect(ChannelParser.parseChannelPage(live)?.videos.continuation == liveToken)

        let playlists = try Fixture.json("channel_blender_playlists.json")
        let listToken = try #require(playlists["contents"]?["twoColumnBrowseResultsRenderer"]?["tabs"]?[5]?["tabRenderer"]?["content"]?["sectionListRenderer"]?["contents"]?[0]?["itemSectionRenderer"]?["contents"]?[0]?["gridRenderer"]?["items"]?[30]?["continuationItemRenderer"]?["continuationEndpoint"]?["continuationCommand"]?["token"]?.string)
        #expect(ChannelParser.parseTab(playlists).continuation == listToken)
        #expect(listToken != liveToken)
    }

    // MARK: Tabs

    @Test func liveTabItemsAreFinishedStreams() throws {
        let p = ChannelParser.parseTab(try Fixture.json("channel_blender_live.json"))
        let first = try #require(p.items.first?.video)
        #expect(first.id == "H5TGt-susIY")
        #expect(first.durationSeconds == 4063)   // 1:07:43
        #expect(first.viewCountText == "23K views")
        #expect(first.viewCount == 23_000)
        #expect(first.publishedText == "Streamed 5 days ago")
        #expect(!first.isLive && !first.isUpcoming && !first.isShort)
        #expect(p.continuation != nil)
    }

    @Test func playlistsTabKeepsThePodcastLockup() throws {
        let p = ChannelParser.parseTab(try Fixture.json("channel_blender_playlists.json"))
        let podcast = try #require(p.items.compactMap { item -> PlaylistSummary? in
            if case .playlist(let playlist) = item { playlist } else { nil }
        }.first { $0.id == "PLa1F2ddGya__t5L-fgRpzUZmbjFLTDI1o" })
        #expect(podcast.title == "Blender Conference 2022 Podcasts")
        #expect(podcast.videoCountText == "8 episodes")
        #expect(podcast.videoCount == 8)
    }

    @Test func tabsAreMappedByParamsNotByTitle() throws {
        // Titles are localized: scramble them and the available tabs must not change.
        var json = try Fixture.json("channel_blender_videos.json")
        json = BrowseJSONEdit.replacingEveryValue(forKey: "title", in: json) { value in
            value.string != nil ? .string("Registerkarte") : value
        }
        let page = try #require(ChannelParser.parseChannelPage(json))
        #expect(page.availableTabs == [.videos, .live, .playlists])
    }

    @Test func availableTabsFollowTheFixedOrderAndOnlyThosePresent() throws {
        // Reverse the tab list and drop the Live tab: still Videos then Playlists.
        var json = try Fixture.json("channel_blender_videos.json")
        json = BrowseJSONEdit.replacingFirstValue(forKey: "tabs", in: json) { tabs in
            guard var list = tabs.array else { return tabs }
            list.removeAll { $0["tabRenderer"]?["endpoint"]?["browseEndpoint"]?["params"]?.string?.hasPrefix("EgdzdHJlYW1z") == true }
            return .array(list.reversed())
        }
        let page = try #require(ChannelParser.parseChannelPage(json))
        #expect(page.availableTabs == [.videos, .playlists])
        // The selected tab is still found, wherever it sits in the list.
        #expect(page.videos.items.count == 30)
    }

    // MARK: Header

    @Test func headerFromEveryTabResponseIsTheSame() throws {
        let names = ["channel_blender_videos.json", "channel_blender_live.json", "channel_blender_playlists.json",
                     "channel_blender_shorts.json", "channel_blender_home.json"]
        var headers: [ChannelHeader] = []
        for name in names {
            let page = try #require(ChannelParser.parseChannelPage(try Fixture.json(name)), "\(name)")
            headers.append(page.header)
            #expect(page.availableTabs == [.videos, .live, .playlists], "\(name)")
        }
        #expect(Set(headers).count == 1)
    }

    @Test func headerDescriptionAndImages() throws {
        let page = try #require(ChannelParser.parseChannelPage(try Fixture.json("channel_blender_videos.json")))
        #expect(page.header.description?.hasPrefix("Official YouTube channel for Blender") == true)
        #expect(page.header.avatarURL?.absoluteString.contains("=s160-") == true)   // the largest avatar rendition
        #expect(page.header.bannerURL?.absoluteString.contains("=w1707-") == true)  // wide enough for a phone at 3x
        #expect(page.header.ref == ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender", avatarURL: page.header.avatarURL, handle: "@BlenderOfficial"))
    }

    /// A channel response with just a header whose count row holds `counts` (after the row with the @handle).
    private func headerResponse(counts: [String]) -> JSON {
        let parts = JSON.array(counts.map { JSON.object(["text": .object(["content": .string($0)])]) })
        return [
            "header": ["pageHeaderRenderer": ["content": ["pageHeaderViewModel": [
                "title": ["dynamicTextViewModel": ["text": ["content": "Kanal"]]],
                "metadata": ["contentMetadataViewModel": ["metadataRows": [
                    ["metadataParts": [["text": ["content": "@kanal"]]]],
                    ["metadataParts": parts],
                ]]],
            ]]]],
            "metadata": ["channelMetadataRenderer": ["externalId": "UCabc1234567890123456789"]],
        ]
    }

    struct HeaderCounts: Sendable, CustomTestStringConvertible {
        var counts: [String]
        var subscribers: String?
        var videos: String?
        var testDescription: String { counts.joined(separator: " | ") }
    }

    @Test(arguments: [
        HeaderCounts(counts: ["1.25M subscribers", "1.5K videos"], subscribers: "1.25M subscribers", videos: "1.5K videos"),
        // Languages that say "videos" like English but not "subscribers": the other count is the subscribers.
        HeaderCounts(counts: ["1,25 Mio. Abonnenten", "1.516 Videos"], subscribers: "1,25 Mio. Abonnenten", videos: "1.516 Videos"),
        HeaderCounts(counts: ["1,25 M de suscriptores", "1,5 mil videos"], subscribers: "1,25 M de suscriptores", videos: "1,5 mil videos"),
        HeaderCounts(counts: ["1,25 Mln di iscritti", "1,5 Mila video"], subscribers: "1,25 Mln di iscritti", videos: "1,5 Mila video"),
        // Languages with neither word: YouTube's order, subscribers first.
        HeaderCounts(counts: ["1,25 M d’abonnés", "1,5 k vidéos"], subscribers: "1,25 M d’abonnés", videos: "1,5 k vidéos"),
        HeaderCounts(counts: ["チャンネル登録者数 125万人", "動画 1,500本"], subscribers: "チャンネル登録者数 125万人", videos: "動画 1,500本"),
        // A hidden subscriber count leaves only the videos.
        HeaderCounts(counts: ["1.5K videos"], subscribers: nil, videos: "1.5K videos"),
        HeaderCounts(counts: ["1.516 Videos"], subscribers: nil, videos: "1.516 Videos"),
        HeaderCounts(counts: ["1.25M subscribers"], subscribers: "1.25M subscribers", videos: nil),
        HeaderCounts(counts: [], subscribers: nil, videos: nil),
    ])
    func headerCountsInAnyLanguage(_ example: HeaderCounts) throws {
        let page = try #require(ChannelParser.parseChannelPage(headerResponse(counts: example.counts)))
        #expect(page.header.handle == "@kanal")
        #expect(page.header.subscriberCountText == example.subscribers)
        #expect(page.header.videoCountText == example.videos)
    }

    // MARK: Items carry the channel of the page

    @Test func tabItemsWithoutAChannelGetThePagesChannel() throws {
        // Channel tab lockups show no channel name of their own.
        let page = try #require(ChannelParser.parseChannelPage(try Fixture.json("channel_blender_videos.json")))
        let videos = page.videos.items.compactMap(\.video)
        #expect(videos.count == 30)
        #expect(videos.allSatisfy { $0.channel == page.header.ref })

        let live = ChannelParser.parseTab(try Fixture.json("channel_blender_live.json"))
        #expect(live.items.compactMap(\.video).allSatisfy { $0.channel?.id == "UCSMOQeBJ2RAnuFungnQOxLg" })

        let shorts = ChannelParser.parseTab(try Fixture.json("channel_blender_shorts.json"))
        #expect(shorts.items.compactMap(\.video).allSatisfy { $0.channel?.id == "UCSMOQeBJ2RAnuFungnQOxLg" && $0.isShort })

        let playlists = ChannelParser.parseTab(try Fixture.json("channel_blender_playlists.json"))
        let owners = playlists.items.compactMap { item -> ChannelRef? in
            if case .playlist(let playlist) = item { playlist.channel } else { nil }
        }
        #expect(owners.count == 30)
        // Each playlist lockup has a link to the channel on its "Playlist" label; that label is not the channel's name.
        #expect(Set(owners) == [page.header.ref])
        #expect(owners.allSatisfy { $0.name == "Blender" })
    }

    // MARK: Home tab

    @Test func homeTabParsesWithoutTrouble() throws {
        // The Home tab is shelves, not a grid: whatever videos and playlists are in there come back, no crash,
        // and nothing from the about panel or the featured-video player.
        let json = try Fixture.json("channel_blender_home.json")
        let page = try #require(ChannelParser.parseChannelPage(json))
        #expect(page.header.id == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(!page.videos.items.isEmpty)
        #expect(ChannelParser.parseTab(json).items.count == page.videos.items.count)
    }

    @Test func anonymousHomeIsEmpty() throws {
        let json = try Fixture.json("browse_home_anon.json")
        #expect(ChannelParser.parseTab(json).items.isEmpty)
        #expect(ChannelParser.parseTab(json).continuation == nil)
        #expect(ChannelParser.parseChannelPage(json) == nil)
    }

    // MARK: Continuations

    /// The grid items of a tab response, wrapped the way `browse` answers a continuation request.
    private func continuationResponse(from tabResponse: JSON, tabIndex: Int) throws -> JSON {
        let content = try #require(tabResponse["contents"]?["twoColumnBrowseResultsRenderer"]?["tabs"]?[tabIndex]?["tabRenderer"]?["content"])
        let items = try #require(content.first("richGridRenderer")?["contents"] ?? content.first("gridRenderer")?["items"])
        return [
            "responseContext": ["visitorData": "x"],
            "onResponseReceivedActions": [[
                "clickTrackingParams": "abc",
                "appendContinuationItemsAction": ["continuationItems": items, "targetId": "browse-feed"],
            ]],
        ]
    }

    @Test func continuationPage() throws {
        let tab = try Fixture.json("channel_blender_videos.json")
        let page = ChannelParser.parseContinuation(try continuationResponse(from: tab, tabIndex: 1))
        #expect(page.items.count == 30)
        #expect(page.items.first?.video?.id == "mHrHLqQj7Ts")
        #expect(page.continuation == ChannelParser.parseTab(tab).continuation)
    }

    @Test func continuationAlsoReadsTheOtherActionKeys() throws {
        let tab = try Fixture.json("channel_blender_live.json")
        var response = try continuationResponse(from: tab, tabIndex: 3)
        let actions = try #require(response["onResponseReceivedActions"])
        response = ["onResponseReceivedEndpoints": actions]
        #expect(ChannelParser.parseContinuation(response).items.count == 30)
        response = ["onResponseReceivedCommands": actions]
        #expect(ChannelParser.parseContinuation(response).items.count == 30)
    }

    @Test func aboutPanelContinuationIsAnEmptyPage() throws {
        // channel_blender_videos_cont.json was captured from the about panel's token: it has no videos.
        let page = ChannelParser.parseContinuation(try Fixture.json("channel_blender_videos_cont.json"))
        #expect(page.items.isEmpty)
        #expect(page.continuation == nil)
    }

    @Test func continuationOfATabResponseIsEmpty() throws {
        // A first page is not a continuation; nothing there to append.
        #expect(ChannelParser.parseContinuation(try Fixture.json("channel_blender_videos.json")).items.isEmpty)
    }

    // MARK: Old-style header

    @Test func c4TabbedHeaderIsUnderstood() throws {
        let json: JSON = [
            "header": ["c4TabbedHeaderRenderer": [
                "channelId": "UCabc1234567890123456789",
                "title": "Old Style",
                "navigationEndpoint": ["browseEndpoint": ["browseId": "UCabc1234567890123456789", "canonicalBaseUrl": "/@oldstyle"]],
                "avatar": ["thumbnails": [["url": "https://yt3.ggpht.com/a=s48", "width": 48, "height": 48], ["url": "https://yt3.ggpht.com/a=s88", "width": 88, "height": 88]]],
                "banner": ["thumbnails": [["url": "https://yt3.ggpht.com/b=w1060", "width": 1060, "height": 175]]],
                "subscriberCountText": ["simpleText": "12K subscribers"],
                "videosCountText": ["runs": [["text": "34"], ["text": " videos"]]],
            ]],
            "contents": ["twoColumnBrowseResultsRenderer": ["tabs": [
                ["tabRenderer": ["selected": true, "endpoint": ["browseEndpoint": ["params": "EgZ2aWRlb3PyBgQKAjoA"]], "content": ["richGridRenderer": ["contents": []]]]],
            ]]],
        ]
        let page = try #require(ChannelParser.parseChannelPage(json))
        #expect(page.header.id == "UCabc1234567890123456789")
        #expect(page.header.name == "Old Style")
        #expect(page.header.handle == "@oldstyle")
        #expect(page.header.subscriberCountText == "12K subscribers")
        #expect(page.header.videoCountText == "34 videos")
        #expect(page.header.avatarURL?.absoluteString == "https://yt3.ggpht.com/a=s88")
        #expect(page.header.bannerURL?.absoluteString == "https://yt3.ggpht.com/b=w1060")
        #expect(page.availableTabs == [.videos])
        #expect(page.videos.items.isEmpty)
    }
}
