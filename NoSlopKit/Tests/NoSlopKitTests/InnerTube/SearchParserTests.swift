import Foundation
import Testing
@testable import NoSlopKit

private extension SearchItem {
    var channelSummary: ChannelSummary? {
        if case .channel(let channel) = self { return channel }
        return nil
    }

    var playlistSummary: PlaylistSummary? {
        if case .playlist(let playlist) = self { return playlist }
        return nil
    }
}

@Suite struct SearchParserTests {
    // MARK: From the plan

    @Test func searchInitialPage() throws {
        let p = SearchParser.parse(try Fixture.json("search_blender_tutorial.json"))
        let videos = p.items.compactMap(\.video)
        // 17 videoRenderers + 5 shortsLockupViewModels. The plan counted the 17 videoRenderers as regular videos, but
        // one of them (qAJZC5kOpOE, "Blender Quick Start Guide in 1 Minute!") is itself a Short: its link is
        // /shorts/qAJZC5kOpOE, its navigation endpoint is a reelWatchEndpoint and its overlay style is SHORTS.
        // Shorts must come back flagged, so the split is 16 regular videos and 6 Shorts (the 5 shelf items + that one).
        #expect(videos.count == 22)
        #expect(videos.filter { !$0.isShort }.count == 16)
        #expect(videos.filter(\.isShort).count == 6)
        #expect(p.items.filter { if case .channel = $0 { true } else { false } }.count == 1)
        #expect(p.items.filter { if case .playlist = $0 { true } else { false } }.count == 1)
        #expect(p.items.count == 24)
        #expect(p.continuation != nil)

        let v = try #require(videos.first { !$0.isShort })
        #expect(v.id == "z-Xl9tGqH14")
        #expect(v.title == "Beginner Blender Tutorial (2026)")
        #expect(v.durationSeconds == 15550)
        #expect(v.viewCount == 2_763_792)
        #expect(v.viewCountText == "2,763,792 views")
        #expect(v.publishedText == "9 months ago")
        #expect(v.channel?.name == "Blender Guru")
        #expect(v.channel?.id == "UCOKHwx1VCdgnxwbjyb9Iu1g")
        #expect(v.channel?.avatarURL != nil)

        let s = try #require(videos.first { $0.isShort })
        #expect(s.id == "gIjBeEvDXew")
        #expect(s.title == "Noob vs PRO: Realistic Clothes in Blender")
        #expect(s.viewCountText == "810K views")
    }

    @Test func theSeventeenVideoRenderersIncludeOneShort() throws {
        // Where the plan's "17 regular + 5 Shorts" comes from, and why it is 16 + 6: the capture has 17 videoRenderers
        // and 5 shortsLockupViewModels, and one of the videoRenderers is a /shorts/ link.
        let json = try Fixture.json("search_blender_tutorial.json")
        let renderers = json.findAll("videoRenderer")
        #expect(renderers.count == 17)
        #expect(json.findAll("shortsLockupViewModel").count == 5)
        let reels = renderers.filter { $0["navigationEndpoint"]?["reelWatchEndpoint"] != nil }
        #expect(reels.compactMap { $0["videoId"]?.string } == ["qAJZC5kOpOE"])
        #expect(reels.first?["navigationEndpoint"]?["commandMetadata"]?["webCommandMetadata"]?["url"]?.string == "/shorts/qAJZC5kOpOE")
        let shortOverlays = renderers.filter { renderer in
            renderer["thumbnailOverlays"]?.array?.contains { $0["thumbnailOverlayTimeStatusRenderer"]?["style"]?.string == "SHORTS" } == true
        }
        #expect(shortOverlays.compactMap { $0["videoId"]?.string } == ["qAJZC5kOpOE"])
    }

    @Test func searchChannelQuirk() throws {
        // channelRenderer: subscriberCountText holds the @handle, videoCountText holds the subscribers.
        let p = SearchParser.parse(try Fixture.json("search_blender_tutorial.json"))
        let channel = try #require(p.items.compactMap(\.channelSummary).first)
        #expect(channel.id == "UCOKHwx1VCdgnxwbjyb9Iu1g")
        #expect(channel.name == "Blender Guru")
        #expect(channel.handle == "@blenderguru")
        #expect(channel.subscriberCountText == "3.45M subscribers")
        // YouTube gives no video count for a channel in search results, and the subscribers must not leak into it.
        #expect(channel.videoCountText == nil)
        // The avatar comes as protocol-relative URLs; the largest rendition wins.
        #expect(channel.avatarURL?.scheme == "https")
        #expect(channel.avatarURL?.absoluteString.contains("=s176-") == true)
        #expect(channel.descriptionSnippet?.hasPrefix("Hi I'm Andrew Price, and I create tutorials") == true)
    }

    @Test func searchPlaylistLockup() throws {
        let p = SearchParser.parse(try Fixture.json("search_blender_tutorial.json"))
        let playlist = try #require(p.items.compactMap(\.playlistSummary).first)
        #expect(playlist.id == "PLjEaoINr3zgEPv5y--4MKpciLaoQYZB1Z")
        #expect(playlist.title == "Blender 4.0 Beginner Donut Tutorial (Old)")
        #expect(!playlist.thumbnails.isEmpty)
        #expect(playlist.thumbnails.map(\.width) == [360, 720])
        #expect(playlist.videoCount == 14)
        #expect(playlist.videoCountText == "14 videos")
        // The channel is the first metadata part, the one that links to the channel ("Blender Guru" · "Playlist").
        #expect(playlist.channel?.name == "Blender Guru")
        #expect(playlist.channel?.id == "UCOKHwx1VCdgnxwbjyb9Iu1g")
        #expect(playlist.channel?.handle == "@blenderguru")
    }

    @Test func searchContinuation() throws {
        let p = SearchParser.parse(try Fixture.json("search_blender_tutorial_cont.json"))
        #expect(p.items.compactMap(\.video).count == 19)
        #expect(p.continuation != nil)
        // Of those 19 videoRenderers, 12 are Shorts (reelWatchEndpoint) and one more item is a playlist lockup.
        #expect(p.items.compactMap(\.video).filter(\.isShort).count == 12)
        #expect(p.items.count == 20)
        #expect(p.items.compactMap(\.playlistSummary).count == 1)
    }

    @Test func searchChannelsOnly() throws {
        let p = SearchParser.parse(try Fixture.json("search_channels_only.json"))
        let channels = p.items.compactMap(\.channelSummary)
        #expect(channels.count == 20)
        #expect(p.items.compactMap(\.video).isEmpty)
        #expect(p.items.count == 20)   // the 5 ad slots between them are gone
        #expect(p.continuation != nil)
        // Every result has the @handle / subscribers swap.
        #expect(channels.allSatisfy { $0.handle?.hasPrefix("@") == true })
        #expect(channels.allSatisfy { $0.subscriberCountText?.contains("subscribers") == true })
        #expect(channels.map(\.id).prefix(3) == ["UC6pJGaMdx5Ter_8zYbLoRgA", "UCSMOQeBJ2RAnuFungnQOxLg", "UCOKHwx1VCdgnxwbjyb9Iu1g"])
        #expect(Set(channels.map(\.id)).count == 20)
    }

    @Test func searchPlaylistsOnly() throws {
        // 17 PLAYLIST and 3 COURSE lockups.
        let p = SearchParser.parse(try Fixture.json("search_playlists_only.json"))
        let playlists = p.items.compactMap(\.playlistSummary)
        #expect(playlists.count == 20)
        #expect(p.items.count == 20)
        #expect(p.continuation != nil)
        #expect(playlists.allSatisfy { !$0.title.isEmpty && !$0.thumbnails.isEmpty && $0.channel != nil })

        let first = try #require(playlists.first)
        #expect(first.id == "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        #expect(first.title == "Blender for Complete Beginners Tutorial Series")
        #expect(first.channel?.name == "Ryan King Art")
        #expect(first.channel?.id == "UCIXjev1_mJ1plJhF9lGarQg")
        #expect(first.videoCount == 14)

        let course = try #require(playlists.first { $0.id == "PLjEaoINr3zgGUwGwXlj9kBe7TrVWNjkyv" })
        #expect(course.title == "Blender Donut Tutorial (2025)")
        #expect(course.videoCountText == "8 lessons")
        #expect(course.videoCount == 8)
        #expect(course.channel?.name == "Blender Guru")
    }

    // MARK: More

    @Test func searchVideosOnly() throws {
        let p = SearchParser.parse(try Fixture.json("search_videos_only.json"))
        let videos = p.items.compactMap(\.video)
        #expect(videos.count == 20)
        #expect(p.items.count == 20)   // 2 ad slots dropped
        #expect(videos.filter(\.isShort).isEmpty)
        #expect(videos.prefix(3).map(\.id) == ["z-Xl9tGqH14", "peSv5IT5Ve4", "7VIJNnPXfqI"])
        #expect(videos.allSatisfy { $0.durationSeconds != nil && $0.viewCount != nil && $0.channel != nil })
        #expect(p.continuation != nil)
    }

    @Test func searchKeepsDocumentOrder() throws {
        let p = SearchParser.parse(try Fixture.json("search_blender_tutorial.json"))
        #expect(p.items.map(\.id) == [
            "video:z-Xl9tGqH14", "video:peSv5IT5Ve4", "video:K7__BjW4UWE",
            "channel:UCOKHwx1VCdgnxwbjyb9Iu1g",
            "video:7VIJNnPXfqI", "video:Lxem4yMs5Dg", "video:ffDbEUVhoMU", "video:Ci3Has4L5W4",
            "playlist:PLjEaoINr3zgEPv5y--4MKpciLaoQYZB1Z",
            "video:nESaz92SJ0w", "video:smluafHtCeY", "video:-tbSCMbJA6o",
            // the Shorts shelf
            "video:gIjBeEvDXew", "video:w29pAeH_xvU", "video:13PdfUES_lw", "video:XplZvYsRNSU", "video:a1OIIMqWC6M",
            "video:QPh8h0hWkg0", "video:W337AL7n3dc", "video:fiX0sO2ZYZ0", "video:DDeB4tDVCGY", "video:8_0RptMbhe0",
            "video:qAJZC5kOpOE", "video:K1UyEdmSttQ",
        ])
    }

    @Test func searchContinuationTokensAreTheListsOwn() throws {
        let initial = try Fixture.json("search_blender_tutorial.json")
        let expected = try #require(initial["contents"]?["twoColumnSearchResultsRenderer"]?["primaryContents"]?["sectionListRenderer"]?["contents"]?[1]?["continuationItemRenderer"]?["continuationEndpoint"]?["continuationCommand"]?["token"]?.string)
        #expect(SearchParser.parse(initial).continuation == expected)

        let more = try Fixture.json("search_blender_tutorial_cont.json")
        let moreExpected = try #require(more["onResponseReceivedCommands"]?[0]?["appendContinuationItemsAction"]?["continuationItems"]?[1]?["continuationItemRenderer"]?["continuationEndpoint"]?["continuationCommand"]?["token"]?.string)
        #expect(SearchParser.parse(more).continuation == moreExpected)
        #expect(expected != moreExpected)
    }

    @Test func aFirstPageHasNoAppendedItemsAndViceVersa() throws {
        // The initial response's onResponseReceivedCommands carries an ads command, not items.
        let initial = try Fixture.json("search_blender_tutorial.json")
        #expect(initial["onResponseReceivedCommands"] != nil)
        #expect(ItemParser.continuationItems(in: initial) == nil)
        // A continuation has no `contents`, and parses all the same.
        let more = try Fixture.json("search_blender_tutorial_cont.json")
        #expect(more["contents"] == nil)
        #expect(SearchParser.parse(more).items.count == 20)
    }

    @Test func searchShortsFromTheShelf() throws {
        let p = SearchParser.parse(try Fixture.json("search_blender_tutorial.json"))
        let shelf = p.items.compactMap(\.video).filter { ["gIjBeEvDXew", "w29pAeH_xvU", "13PdfUES_lw", "XplZvYsRNSU", "a1OIIMqWC6M"].contains($0.id) }
        #expect(shelf.count == 5)
        #expect(shelf.allSatisfy { $0.isShort })
        #expect(shelf.map(\.viewCountText) == ["810K views", "1.1M views", "2M views", "3.9M views", "8.3M views"])
        #expect(shelf.map(\.viewCount) == [810_000, 1_100_000, 2_000_000, 3_900_000, 8_300_000])
        #expect(shelf.dropFirst().first?.title == "Rigging Among Us Blender - EASY #blender #3d #amongus #tutorial #blender3d")
        // The shelf gives no duration and no channel; the thumbnail is the portrait frame.
        #expect(shelf.allSatisfy { $0.durationSeconds == nil && $0.channel == nil })
        #expect(shelf.allSatisfy { !$0.thumbnails.isEmpty })
    }

    @Test func shortInsideVideoRendererIsFlagged() throws {
        let p = SearchParser.parse(try Fixture.json("search_blender_tutorial.json"))
        let short = try #require(p.items.compactMap(\.video).first { $0.id == "qAJZC5kOpOE" })
        #expect(short.isShort)
        #expect(short.title == "Blender Quick Start Guide in 1 Minute!")
        #expect(short.durationSeconds == 60)
        // Still a normal videoRenderer: it has a channel and counts.
        #expect(short.channel != nil)
        #expect(short.viewCount != nil)
    }

    @Test func searchResultsNeverContainsAnAdOrAnAIBlock() throws {
        for name in ["search_blender_tutorial.json", "search_blender_tutorial_cont.json", "search_channels_only.json",
                     "search_playlists_only.json", "search_videos_only.json"] {
            let json = try Fixture.json(name)
            let p = SearchParser.parse(json)
            // Everything returned is a real renderer: the item count is exactly the renderer count.
            let renderers = json.findAll("videoRenderer").count + json.findAll("shortsLockupViewModel").count
                + json.findAll("channelRenderer").count + json.findAll("lockupViewModel").count
            #expect(p.items.count == renderers, "\(name)")
            #expect(!p.items.isEmpty)
        }
    }
}
