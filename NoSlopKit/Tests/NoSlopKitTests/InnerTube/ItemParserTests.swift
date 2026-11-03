import Foundation
import Testing
@testable import NoSlopKit

/// Renderer-level behaviour that the captured fixtures don't show (live, upcoming, members-only, other locales,
/// the older renderer names). The JSON mirrors the shapes of the captures.
@Suite struct ItemParserTests {
    private func json(_ text: String) throws -> JSON {
        try JSON(data: Data(text.utf8))
    }

    // MARK: videoRenderer

    @Test func liveVideoRenderer() throws {
        let renderer = try json(#"""
        {"videoId":"liveliveli1","title":{"runs":[{"text":"Lofi Radio 24/7"}]},
         "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/liveliveli1/hq720.jpg","width":720,"height":404}]},
         "viewCountText":{"runs":[{"text":"1,234"},{"text":" watching"}]},
         "ownerText":{"runs":[{"text":"Lofi Girl","navigationEndpoint":{"browseEndpoint":{"browseId":"UCSJ4gkVC6NrvII8umztf0Ow","canonicalBaseUrl":"/@LofiGirl"}}}]},
         "badges":[{"metadataBadgeRenderer":{"style":"BADGE_STYLE_TYPE_LIVE_NOW","label":"LIVE NOW"}}],
         "thumbnailOverlays":[{"thumbnailOverlayTimeStatusRenderer":{"style":"LIVE","text":{"runs":[{"text":"LIVE"}]}}}]}
        """#)
        let video = try #require(ItemParser.video(fromVideoRenderer: renderer))
        #expect(video.id == "liveliveli1")
        #expect(video.isLive)
        #expect(!video.isUpcoming && !video.isShort && !video.isMembersOnly)
        #expect(video.durationSeconds == nil)
        // "1,234 watching" is a viewer count, not a view count: the app shows YouTube's text for it.
        #expect(video.viewCount == nil)
        #expect(video.viewCountText == "1,234 watching")
        #expect(video.channel == ChannelRef(id: "UCSJ4gkVC6NrvII8umztf0Ow", name: "Lofi Girl", avatarURL: nil, handle: "@LofiGirl"))
    }

    @Test func liveOverlayAloneMarksTheVideoLive() throws {
        let renderer = try json(#"""
        {"videoId":"liveliveli2","title":{"simpleText":"Live"},
         "thumbnailOverlays":[{"thumbnailOverlayTimeStatusRenderer":{"style":"LIVE"}}]}
        """#)
        #expect(ItemParser.video(fromVideoRenderer: renderer)?.isLive == true)
    }

    @Test func upcomingVideoRenderer() throws {
        let renderer = try json(#"""
        {"videoId":"upcoming001","title":{"simpleText":"Big Premiere"},
         "upcomingEventData":{"startTime":"1793706636","upcomingEventText":{"runs":[{"text":"Scheduled for "},{"text":"11/3/26, 8:00 PM"}]}},
         "viewCountText":{"simpleText":"12 waiting"},
         "thumbnailOverlays":[{"thumbnailOverlayTimeStatusRenderer":{"style":"UPCOMING","text":{"simpleText":"UPCOMING"}}}]}
        """#)
        let video = try #require(ItemParser.video(fromVideoRenderer: renderer))
        #expect(video.isUpcoming)
        #expect(!video.isLive)
        #expect(video.publishedText == "Scheduled for 11/3/26, 8:00 PM")
        #expect(video.publishedAt == Date(timeIntervalSince1970: 1_793_706_636))
        #expect(video.viewCount == nil)
        #expect(video.viewCountText == "12 waiting")
        #expect(video.durationSeconds == nil)
    }

    @Test func membersOnlyVideoRenderer() throws {
        let renderer = try json(#"""
        {"videoId":"members0001","title":{"runs":[{"text":"Members only video"}]},"lengthText":{"simpleText":"10:00"},
         "badges":[{"metadataBadgeRenderer":{"style":"BADGE_STYLE_TYPE_MEMBERS_ONLY","label":"Members only"}}]}
        """#)
        let video = try #require(ItemParser.video(fromVideoRenderer: renderer))
        #expect(video.isMembersOnly)
        #expect(video.durationSeconds == 600)
        #expect(!video.isLive)
    }

    @Test func shortVideoRendererByEndpointOrOverlay() throws {
        let byEndpoint = try json(#"""
        {"videoId":"shortshort01","title":{"simpleText":"s"},"navigationEndpoint":{"reelWatchEndpoint":{"videoId":"shortshort01"}}}
        """#)
        #expect(ItemParser.video(fromVideoRenderer: byEndpoint)?.isShort == true)
        let byOverlay = try json(#"""
        {"videoId":"shortshort02","title":{"simpleText":"s"},"thumbnailOverlays":[{"thumbnailOverlayTimeStatusRenderer":{"style":"SHORTS"}}]}
        """#)
        #expect(ItemParser.video(fromVideoRenderer: byOverlay)?.isShort == true)
        let byURL = try json(#"""
        {"videoId":"shortshort03","title":{"simpleText":"s"},"navigationEndpoint":{"commandMetadata":{"webCommandMetadata":{"url":"/shorts/shortshort03","webPageType":"WEB_PAGE_TYPE_SHORTS"}}}}
        """#)
        #expect(ItemParser.video(fromVideoRenderer: byURL)?.isShort == true)
        let regular = try json(#"""
        {"videoId":"regular0001","title":{"simpleText":"r"},"navigationEndpoint":{"watchEndpoint":{"videoId":"regular0001"}}}
        """#)
        #expect(ItemParser.video(fromVideoRenderer: regular)?.isShort == false)
    }

    @Test func compactVideoRendererWithTheOlderFieldNames() throws {
        let renderer = try json(#"""
        {"videoId":"compact0001","title":{"simpleText":"Old Style"},
         "longBylineText":{"runs":[{"text":"  Some Channel ","navigationEndpoint":{"browseEndpoint":{"browseId":"UCxxxxxxxxxxxxxxxxxxxxxx","canonicalBaseUrl":"/c/SomeChannel"}}}]},
         "channelThumbnail":{"thumbnails":[{"url":"https://yt3.ggpht.com/c=s68","width":68,"height":68}]},
         "lengthText":{"simpleText":"3:21"},"viewCountText":{"simpleText":"1,000 views"},"shortViewCountText":{"simpleText":"1K views"},
         "publishedTimeText":{"simpleText":"2 days ago"},"thumbnail":{"thumbnails":[{"url":"//i.ytimg.com/vi/compact0001/mq.jpg","width":320,"height":180}]}}
        """#)
        let video = try #require(ItemParser.video(fromVideoRenderer: renderer))
        #expect(video.title == "Old Style")
        #expect(video.channel?.id == "UCxxxxxxxxxxxxxxxxxxxxxx")
        #expect(video.channel?.name == "Some Channel")
        #expect(video.channel?.handle == nil)   // /c/… is a vanity path, not a handle
        #expect(video.channel?.avatarURL?.absoluteString == "https://yt3.ggpht.com/c=s68")
        #expect(video.durationSeconds == 201)
        #expect(video.viewCount == 1000)
        #expect(video.viewCountText == "1,000 views")
        #expect(video.publishedText == "2 days ago")
        #expect(video.thumbnails.first?.url.absoluteString == "https://i.ytimg.com/vi/compact0001/mq.jpg")
    }

    @Test func shortViewCountTextIsTheFallback() throws {
        let renderer = try json(#"{"videoId":"fallback001","title":{"simpleText":"t"},"shortViewCountText":{"simpleText":"2.7M views"}}"#)
        let video = try #require(ItemParser.video(fromVideoRenderer: renderer))
        #expect(video.viewCountText == "2.7M views")
        #expect(video.viewCount == 2_700_000)
    }

    @Test func gridVideoRenderer() throws {
        let renderer = try json(#"""
        {"videoId":"gridvideo01","title":{"runs":[{"text":"Grid"}]},"publishedTimeText":{"simpleText":"1 year ago"},
         "viewCountText":{"simpleText":"5 views"},
         "shortBylineText":{"runs":[{"text":"Chan","navigationEndpoint":{"browseEndpoint":{"browseId":"UCgrid"}}}]}}
        """#)
        let items = ItemParser.items(in: [["gridVideoRenderer": renderer]])
        let video = try #require(items.first?.video)
        #expect(video.id == "gridvideo01")
        #expect(video.channel?.id == "UCgrid")
        #expect(video.viewCount == 5)
    }

    @Test func playlistVideoRenderer() throws {
        let renderer = try json(#"""
        {"videoId":"plvideo0001","title":{"runs":[{"text":"Part 1"}]},"lengthSeconds":"125","isPlayable":true,
         "shortBylineText":{"runs":[{"text":"Chan","navigationEndpoint":{"browseEndpoint":{"browseId":"UCpl","canonicalBaseUrl":"/@chan"}}}]},
         "videoInfo":{"runs":[{"text":"296K views"},{"text":" • "},{"text":"2 years ago"}]},
         "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/plvideo0001/hq.jpg","width":480,"height":360}]}}
        """#)
        let video = try #require(ItemParser.video(fromVideoRenderer: renderer))
        #expect(video.durationSeconds == 125)
        #expect(video.viewCount == 296_000)
        #expect(video.viewCountText == "296K views")
        #expect(video.publishedText == "2 years ago")
        #expect(video.channel?.handle == "@chan")

        // Private and deleted entries keep their id and a placeholder title but cannot be played.
        let deleted = try json(#"{"videoId":"deleted0001","title":{"runs":[{"text":"[Deleted video]"}]},"isPlayable":false}"#)
        #expect(ItemParser.video(fromVideoRenderer: deleted) == nil)
        #expect(ItemParser.items(in: [["playlistVideoRenderer": deleted]]).isEmpty)
    }

    @Test func reelItemRenderer() throws {
        let renderer = try json(#"""
        {"videoId":"reelitem001","headline":{"simpleText":"A reel"},"viewCountText":{"simpleText":"1.2M views"},
         "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/reelitem001/frame0.jpg","width":405,"height":720}]},
         "navigationEndpoint":{"reelWatchEndpoint":{"videoId":"reelitem001"}}}
        """#)
        let video = try #require(ItemParser.items(in: [["reelItemRenderer": renderer]]).first?.video)
        #expect(video.id == "reelitem001")
        #expect(video.title == "A reel")
        #expect(video.isShort)
        #expect(video.viewCount == 1_200_000)
    }

    @Test func percentEncodedHandlesAreDecoded() throws {
        let renderer = try json(#"""
        {"videoId":"encoded0001","title":{"simpleText":"t"},
         "ownerText":{"runs":[{"text":"テスト","navigationEndpoint":{"browseEndpoint":{"browseId":"UCjp","canonicalBaseUrl":"/@%E3%83%86%E3%82%B9%E3%83%88"}}}]}}
        """#)
        #expect(ItemParser.video(fromVideoRenderer: renderer)?.channel?.handle == "@テスト")
    }

    @Test func videoRendererWithoutIdOrTitleIsSkipped() throws {
        #expect(ItemParser.video(fromVideoRenderer: try json(#"{"title":{"simpleText":"t"}}"#)) == nil)
        #expect(ItemParser.video(fromVideoRenderer: try json(#"{"videoId":"","title":{"simpleText":"t"}}"#)) == nil)
        #expect(ItemParser.video(fromVideoRenderer: try json(#"{"videoId":"abc"}"#)) == nil)
        #expect(ItemParser.video(fromVideoRenderer: try json(#"{"videoId":"abc","title":{"runs":[]}}"#)) == nil)
        #expect(ItemParser.video(fromVideoRenderer: .null) == nil)
        #expect(ItemParser.video(fromVideoRenderer: [:]) == nil)
    }

    @Test func aChannelNeedsBothAnIdAndAName() throws {
        let noID = try json(#"{"videoId":"abc","title":{"simpleText":"t"},"ownerText":{"runs":[{"text":"Only a name"}]}}"#)
        #expect(ItemParser.video(fromVideoRenderer: noID)?.channel == nil)
        let noName = try json(#"{"videoId":"abc","title":{"simpleText":"t"},"ownerText":{"runs":[{"navigationEndpoint":{"browseEndpoint":{"browseId":"UCx"}}}]}}"#)
        #expect(ItemParser.video(fromVideoRenderer: noName)?.channel == nil)
    }

    // MARK: lockupViewModel (video)

    /// A video lockup shaped like the captures. `rows` are the metadata rows (each a list of part texts).
    private func videoLockup(
        id: String = "lockupvid01", title: String = "A lockup", rows: [[String]] = [], badges: [(text: String, style: String)] = [],
        channelID: String? = nil, extra: String = ""
    ) throws -> JSON {
        let rowsJSON = rows.map { row in
            #"{"metadataParts":["# + row.map { #"{"text":{"content":"\#($0)"}}"# }.joined(separator: ",") + "]}"
        }.joined(separator: ",")
        let badgesJSON = badges.map { #"{"thumbnailBadgeViewModel":{"text":"\#($0.text)","badgeStyle":"\#($0.style)"}}"# }.joined(separator: ",")
        let avatar = channelID.map {
            #"""
            ,"image":{"decoratedAvatarViewModel":{"avatar":{"avatarViewModel":{"image":{"sources":[{"url":"https://yt3.ggpht.com/av=s68","width":68,"height":68}]}}},
            "rendererContext":{"commandContext":{"onTap":{"innertubeCommand":{"browseEndpoint":{"browseId":"\#($0)","canonicalBaseUrl":"/@someone"}}}}}}}
            """#
        } ?? ""
        return try json(#"""
        {"contentId":"\#(id)","contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
         "contentImage":{"thumbnailViewModel":{"image":{"sources":[{"url":"https://i.ytimg.com/vi/\#(id)/hq.jpg","width":360,"height":202},{"url":"https://i.ytimg.com/vi/\#(id)/hq720.jpg","width":720,"height":404}]},
           "overlays":[{"thumbnailBottomOverlayViewModel":{"badges":[\#(badgesJSON)]}}]}},
         "metadata":{"lockupMetadataViewModel":{"title":{"content":"\#(title)"}\#(avatar),
           "metadata":{"contentMetadataViewModel":{"metadataRows":[\#(rowsJSON)]}}}}\#(extra)}
        """#)
    }

    @Test func lockupBasics() throws {
        let lockup = try videoLockup(rows: [["Some Channel"], ["9.8K views", "22 hours ago"]], badges: [("4:40", "THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT")], channelID: "UCsome")
        let video = try #require(ItemParser.video(fromLockup: lockup))
        #expect(video.id == "lockupvid01")
        #expect(video.title == "A lockup")
        #expect(video.durationSeconds == 280)
        #expect(video.viewCount == 9_800)
        #expect(video.viewCountText == "9.8K views")
        #expect(video.publishedText == "22 hours ago")
        #expect(video.thumbnails.map(\.width) == [360, 720])
        #expect(video.channel == ChannelRef(id: "UCsome", name: "Some Channel", avatarURL: URL(string: "https://yt3.ggpht.com/av=s68"), handle: "@someone"))
        #expect(!video.isLive && !video.isUpcoming && !video.isShort && !video.isMembersOnly)
    }

    struct MetadataCase: Sendable, CustomTestStringConvertible {
        var rows: [[String]]
        var viewsText: String?
        var views: Int?
        var published: String?
        var live = false
        var upcoming = false

        init(_ rows: [[String]], _ viewsText: String?, _ views: Int?, _ published: String?, live: Bool = false, upcoming: Bool = false) {
            self.rows = rows
            self.viewsText = viewsText
            self.views = views
            self.published = published
            self.live = live
            self.upcoming = upcoming
        }

        var testDescription: String { rows.map { $0.joined(separator: " | ") }.joined(separator: " / ") }
    }

    private static let metadataCases: [MetadataCase] = [
        // Channel tab: one row, no channel.
        MetadataCase([["9.8K views", "22 hours ago"]], "9.8K views", 9_800, "22 hours ago"),
        // Playlist, search and related lockups: the channel row comes first.
        MetadataCase([["Chan"], ["296K views", "2 years ago"]], "296K views", 296_000, "2 years ago"),
        MetadataCase([["Chan"], ["7.8M", "13d ago"]], "7.8M", 7_800_000, "13d ago"),
        MetadataCase([["Chan"], ["7.8M", "13d ago"], []], "7.8M", 7_800_000, "13d ago"),
        MetadataCase([["Chan"], ["1.2B", "17y ago"]], "1.2B", 1_200_000_000, "17y ago"),
        MetadataCase([["Chan"], ["2,763,792 views", "9 months ago"]], "2,763,792 views", 2_763_792, "9 months ago"),
        MetadataCase([["Chan"], ["1 view", "1 minute ago"]], "1 view", 1, "1 minute ago"),
        MetadataCase([["Chan"], ["No views", "3 seconds ago"]], "No views", 0, "3 seconds ago"),
        // Streams and premieres that are over.
        MetadataCase([["Chan"], ["23K views", "Streamed 5 days ago"]], "23K views", 23_000, "Streamed 5 days ago"),
        MetadataCase([["Chan"], ["1.2M", "Streamed 2mo ago"]], "1.2M", 1_200_000, "Streamed 2mo ago"),
        MetadataCase([["Chan"], ["2K views", "Premiered 3 days ago"]], "2K views", 2_000, "Premiered 3 days ago"),
        // Live and upcoming, from the text alone.
        MetadataCase([["Chan"], ["1.2K watching"]], "1.2K watching", nil, nil, live: true),
        MetadataCase([["Chan"], ["12 waiting", "Scheduled for 11/3/26, 8:00 PM"]], "12 waiting", nil, "Scheduled for 11/3/26, 8:00 PM", upcoming: true),
        MetadataCase([["Chan"], ["Scheduled for 11/3/26, 8:00 PM"]], nil, nil, "Scheduled for 11/3/26, 8:00 PM", upcoming: true),
        // Only a date, or only a count.
        MetadataCase([["Chan"], ["5K views"]], "5K views", 5_000, nil),
        MetadataCase([["Chan"], ["5K"]], "5K", 5_000, nil),
        // A channel whose name looks like a date or a count must not be mistaken for one.
        MetadataCase([["Chicago 2K"], ["5K views", "1 day ago"]], "5K views", 5_000, "1 day ago"),
        MetadataCase([["Watching Paint Dry"], ["5K views", "1 day ago"]], "5K views", 5_000, "1 day ago"),
        // Other languages: the position decides, and YouTube's own text is kept without a number (the screens would
        // word a known count in English).
        MetadataCase([["Kanal"], ["9,8 Tsd. Aufrufe", "vor 22 Stunden"]], "9,8 Tsd. Aufrufe", nil, "vor 22 Stunden"),
        MetadataCase([["Canal"], ["1,2 M de visualizaciones", "hace 22 horas"]], "1,2 M de visualizaciones", nil, "hace 22 horas"),
        MetadataCase([["チャンネル"], ["12万 回視聴", "3 日前"]], "12万 回視聴", nil, "3 日前"),
        MetadataCase([["Канал"], ["12 тыс. просмотров", "3 дня назад"]], "12 тыс. просмотров", nil, "3 дня назад"),
        MetadataCase([["Chaîne"], ["2 763 792 vues", "il y a 3 jours"]], "2 763 792 vues", nil, "il y a 3 jours"),
        // Nothing to read.
        MetadataCase([["Chan"]], nil, nil, nil),
        MetadataCase([], nil, nil, nil),
    ]

    @Test(arguments: metadataCases)
    func lockupViewsAndAge(_ example: MetadataCase) throws {
        let video = try #require(ItemParser.video(fromLockup: try videoLockup(rows: example.rows)))
        #expect(video.viewCountText == example.viewsText)
        #expect(video.viewCount == example.views)
        #expect(video.publishedText == example.published)
        #expect(video.isLive == example.live)
        #expect(video.isUpcoming == example.upcoming)
    }

    @Test func liveLockup() throws {
        let lockup = try videoLockup(rows: [["Chan"], ["1.2K watching"]], badges: [("LIVE", "THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE")])
        let video = try #require(ItemParser.video(fromLockup: lockup))
        #expect(video.isLive)
        #expect(!video.isUpcoming)
        #expect(video.durationSeconds == nil)
        #expect(video.viewCount == nil)
        #expect(video.viewCountText == "1.2K watching")
        #expect(video.publishedText == nil)
    }

    @Test func liveBadgeStyleAloneIsEnough() throws {
        let lockup = try videoLockup(rows: [["Chan"], ["123 watching", "Started streaming 1 hour ago"]], badges: [("Now", "THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE")])
        let video = try #require(ItemParser.video(fromLockup: lockup))
        #expect(video.isLive)
        #expect(video.durationSeconds == nil)
        #expect(video.viewCount == nil)
        #expect(video.publishedText == "Started streaming 1 hour ago")
    }

    @Test func upcomingLockup() throws {
        let lockup = try videoLockup(rows: [["Chan"], ["12 waiting", "Scheduled for 11/3/26, 8:00 PM"]], badges: [("Upcoming", "THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT")])
        let video = try #require(ItemParser.video(fromLockup: lockup))
        #expect(video.isUpcoming)
        #expect(!video.isLive)
        #expect(video.viewCount == nil)
        #expect(video.viewCountText == "12 waiting")
        #expect(video.publishedText == "Scheduled for 11/3/26, 8:00 PM")
    }

    @Test func premiereLockup() throws {
        let lockup = try videoLockup(rows: [["Chan"], ["Premieres 11/3/26"]], badges: [("Premiere", "THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT")])
        let video = try #require(ItemParser.video(fromLockup: lockup))
        #expect(video.isUpcoming)
        #expect(video.durationSeconds == nil)
    }

    @Test func membersOnlyLockup() throws {
        let lockup = try videoLockup(rows: [["Chan"], ["1K views", "1 day ago"]], badges: [("10:00", "THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT"), ("Members only", "THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT")])
        let video = try #require(ItemParser.video(fromLockup: lockup))
        #expect(video.isMembersOnly)
        #expect(video.durationSeconds == 600)
    }

    @Test func shortInALockupIsFlagged() throws {
        let lockup = try videoLockup(rows: [["Chan"], ["1K views", "1 day ago"]], extra: #","rendererContext":{"commandContext":{"onTap":{"innertubeCommand":{"reelWatchEndpoint":{"videoId":"lockupvid01"}}}}}"#)
        #expect(ItemParser.video(fromLockup: lockup)?.isShort == true)
    }

    @Test func lockupWithoutIdOrTitleIsSkipped() throws {
        #expect(ItemParser.video(fromLockup: try videoLockup(id: "")) == nil)
        #expect(ItemParser.video(fromLockup: try videoLockup(title: "")) == nil)
        #expect(ItemParser.video(fromLockup: try videoLockup(title: "   ")) == nil)
        var noMetadata = try videoLockup()
        noMetadata = BrowseJSONEdit.removingDirectKey("metadata", in: noMetadata)
        #expect(ItemParser.video(fromLockup: noMetadata) == nil)
    }

    @Test func lockupTypeDecidesVideoOrPlaylist() throws {
        let video = try videoLockup()
        #expect(ItemParser.video(fromLockup: video) != nil)
        #expect(ItemParser.playlist(fromLockup: video) == nil)

        let playlist = try playlistLockup()
        #expect(ItemParser.playlist(fromLockup: playlist) != nil)
        #expect(ItemParser.video(fromLockup: playlist) == nil)

        // A type this parser does not know is neither.
        var unknown = video
        unknown = BrowseJSONEdit.replacingFirstValue(forKey: "contentType", in: unknown) { _ in "LOCKUP_CONTENT_TYPE_SOMETHING_NEW" }
        #expect(ItemParser.video(fromLockup: unknown) == nil)
        #expect(ItemParser.playlist(fromLockup: unknown) == nil)
        #expect(ItemParser.items(in: [["lockupViewModel": unknown]]).isEmpty)
    }

    @Test func lockupWithoutATypeIsRecognisedByItsImage() throws {
        let video = BrowseJSONEdit.removingDirectKey("contentType", in: try videoLockup(rows: [["Chan"], ["1K views", "1 day ago"]]))
        #expect(ItemParser.items(in: [["lockupViewModel": video]]).map(\.id) == ["video:lockupvid01"])
        let playlist = BrowseJSONEdit.removingDirectKey("contentType", in: try playlistLockup())
        #expect(ItemParser.items(in: [["lockupViewModel": playlist]]).map(\.id) == ["playlist:PLlockup0001"])
    }

    // MARK: lockupViewModel (playlist)

    private func playlistLockup(
        id: String = "PLlockup0001", type: String = "LOCKUP_CONTENT_TYPE_PLAYLIST", title: String = "A playlist",
        count: String? = "12 videos", firstRow: String = #"[{"text":{"content":"Playlist"}}]"#
    ) throws -> JSON {
        let badge = count.map { #"{"thumbnailOverlayBadgeViewModel":{"thumbnailBadges":[{"thumbnailBadgeViewModel":{"text":"\#($0)"}}]}}"# } ?? ""
        return try json(#"""
        {"contentId":"\#(id)","contentType":"\#(type)",
         "contentImage":{"collectionThumbnailViewModel":{"primaryThumbnail":{"thumbnailViewModel":{
           "image":{"sources":[{"url":"https://i.ytimg.com/vi/x/hq.jpg","width":480,"height":270}]},"overlays":[\#(badge)]}}}},
         "metadata":{"lockupMetadataViewModel":{"title":{"content":"\#(title)"},
           "metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":\#(firstRow)},{"metadataParts":[{"text":{"content":"View full playlist"}}]}]}}}}}
        """#)
    }

    @Test func playlistLockupTypes() throws {
        for type in ["LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_PODCAST", "LOCKUP_CONTENT_TYPE_COURSE"] {
            let playlist = try #require(ItemParser.playlist(fromLockup: try playlistLockup(type: type)), "\(type)")
            #expect(playlist.id == "PLlockup0001")
            #expect(playlist.title == "A playlist")
            #expect(playlist.videoCount == 12)
            #expect(playlist.videoCountText == "12 videos")
            #expect(playlist.thumbnails.map(\.width) == [480])
            // The first part is the kind of list, not a channel.
            #expect(playlist.channel == nil)
        }
    }

    @Test func playlistLockupChannelNeedsALink() throws {
        let linked = #"[{"text":{"content":"Blender Guru","commandRuns":[{"onTap":{"innertubeCommand":{"browseEndpoint":{"browseId":"UCOKHwx1VCdgnxwbjyb9Iu1g","canonicalBaseUrl":"/@blenderguru"}}}}]}},{"text":{"content":"Playlist"}}]"#
        let playlist = try #require(ItemParser.playlist(fromLockup: try playlistLockup(firstRow: linked)))
        #expect(playlist.channel == ChannelRef(id: "UCOKHwx1VCdgnxwbjyb9Iu1g", name: "Blender Guru", avatarURL: nil, handle: "@blenderguru"))
    }

    @Test func aLoneLinkedLabelIsNotAChannel() throws {
        // On a channel's playlist tab the first row is only "Playlist", and that label links to the channel.
        let label = #"[{"text":{"content":"Playlist","commandRuns":[{"onTap":{"innertubeCommand":{"browseEndpoint":{"browseId":"UCOKHwx1VCdgnxwbjyb9Iu1g","canonicalBaseUrl":"/@blenderguru"}}}}]}}]"#
        let playlist = try #require(ItemParser.playlist(fromLockup: try playlistLockup(firstRow: label)))
        #expect(playlist.channel == nil)
    }

    @Test func playlistLockupWithoutACountStillParses() throws {
        let playlist = try #require(ItemParser.playlist(fromLockup: try playlistLockup(count: nil)))
        #expect(playlist.videoCount == nil)
        #expect(playlist.videoCountText == nil)
    }

    @Test func mixesAreNotPlaylistsYouCanOpen() throws {
        // "Mix" lists are generated per viewer and have no playlist page.
        #expect(ItemParser.playlist(fromLockup: try playlistLockup(id: "RDdQw4w9WgXcQ")) == nil)
        #expect(ItemParser.playlist(fromLockup: try playlistLockup(id: "RDCLAK5uy_abc")) == nil)
        #expect(ItemParser.playlist(fromLockup: try playlistLockup(id: "PLRDabc")) != nil)
    }

    @Test func playlistLockupWithoutTitleOrIdIsSkipped() throws {
        #expect(ItemParser.playlist(fromLockup: try playlistLockup(id: "")) == nil)
        #expect(ItemParser.playlist(fromLockup: try playlistLockup(title: "")) == nil)
        let noMetadata = BrowseJSONEdit.removingDirectKey("metadata", in: try playlistLockup())
        #expect(ItemParser.playlist(fromLockup: noMetadata) == nil)
    }

    @Test func oldPlaylistRenderers() throws {
        let playlistRenderer = try json(#"""
        {"playlistId":"PLold0000001","title":{"simpleText":"Old playlist"},"videoCount":"14",
         "thumbnails":[{"thumbnails":[{"url":"https://i.ytimg.com/vi/a/mq.jpg","width":168,"height":94},{"url":"https://i.ytimg.com/vi/a/hq.jpg","width":336,"height":188}]}],
         "longBylineText":{"runs":[{"text":"Chan","navigationEndpoint":{"browseEndpoint":{"browseId":"UCold"}}}]}}
        """#)
        let gridPlaylist = try json(#"""
        {"playlistId":"PLgrid0000001","title":{"runs":[{"text":"Grid playlist"}]},"videoCountText":{"runs":[{"text":"3"},{"text":" videos"}]},
         "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/b/mq.jpg","width":168,"height":94}]}}
        """#)
        let items = ItemParser.items(in: [["playlistRenderer": playlistRenderer], ["gridPlaylistRenderer": gridPlaylist]])
        #expect(items.map(\.id) == ["playlist:PLold0000001", "playlist:PLgrid0000001"])
        try #require(items.count == 2)
        guard case .playlist(let old) = items[0], case .playlist(let grid) = items[1] else {
            Issue.record("expected playlists")
            return
        }
        #expect(old.title == "Old playlist")
        #expect(old.videoCount == 14)
        #expect(old.thumbnails.map(\.width) == [168, 336])
        #expect(old.channel?.id == "UCold")
        #expect(grid.videoCount == 3)
        #expect(grid.videoCountText == "3 videos")
    }

    // MARK: shortsLockupViewModel

    @Test func shortsLockupFallbacks() throws {
        // The id from the entity id when the tap command is missing; no thumbnail data means the ytimg defaults.
        let lockup = try json(#"""
        {"entityId":"shorts-shelf-item-ABCDEFGHIJK","overlayMetadata":{"primaryText":{"content":"A short"},"secondaryText":{"content":"3.9M views"}}}
        """#)
        let short = try #require(ItemParser.short(fromShortsLockup: lockup))
        #expect(short.id == "ABCDEFGHIJK")
        #expect(short.title == "A short")
        #expect(short.isShort)
        #expect(short.viewCount == 3_900_000)
        #expect(short.thumbnails.isEmpty)
        #expect(short.displayThumbnails.count == 3)   // the ytimg defaults

        let noID = try json(#"{"overlayMetadata":{"primaryText":{"content":"A short"}}}"#)
        #expect(ItemParser.short(fromShortsLockup: noID) == nil)
        let noTitle = try json(#"{"entityId":"shorts-shelf-item-ABCDEFGHIJK"}"#)
        #expect(ItemParser.short(fromShortsLockup: noTitle) == nil)
        let wrongPrefix = try json(#"{"entityId":"something-else","overlayMetadata":{"primaryText":{"content":"A short"}}}"#)
        #expect(ItemParser.short(fromShortsLockup: wrongPrefix) == nil)
    }

    // MARK: channelRenderer

    @Test func channelRendererWithoutTheQuirk() throws {
        // Grid channels (and older responses) put the subscribers in subscriberCountText and the videos in videoCountText.
        let renderer = try json(#"""
        {"channelId":"UCAsj9iReHzLEYv9QawGzIOg","title":{"simpleText":"Blender Developers"},
         "thumbnail":{"thumbnails":[{"url":"//yt3.ggpht.com/a=s88","width":88,"height":88},{"url":"//yt3.ggpht.com/a=s176","width":176,"height":176}]},
         "subscriberCountText":{"simpleText":"87.4K subscribers"},"videoCountText":{"runs":[{"text":"144"},{"text":" videos"}]},
         "navigationEndpoint":{"browseEndpoint":{"browseId":"UCAsj9iReHzLEYv9QawGzIOg","canonicalBaseUrl":"/@BlenderDevelopers"}}}
        """#)
        let channel = try #require(ItemParser.channel(fromChannelRenderer: renderer))
        #expect(channel.id == "UCAsj9iReHzLEYv9QawGzIOg")
        #expect(channel.name == "Blender Developers")
        #expect(channel.handle == "@BlenderDevelopers")
        #expect(channel.subscriberCountText == "87.4K subscribers")
        #expect(channel.videoCountText == "144 videos")
        #expect(channel.avatarURL?.absoluteString == "https://yt3.ggpht.com/a=s176")
        #expect(channel.descriptionSnippet == nil)
    }

    @Test func channelRendererQuirkWithoutAnyNavigationEndpoint() throws {
        let renderer = try json(#"""
        {"channelId":"UCx","title":{"simpleText":"Quirky"},"subscriberCountText":{"simpleText":"@quirky"},"videoCountText":{"simpleText":"670K subscribers"}}
        """#)
        let channel = try #require(ItemParser.channel(fromChannelRenderer: renderer))
        #expect(channel.handle == "@quirky")
        #expect(channel.subscriberCountText == "670K subscribers")
        #expect(channel.videoCountText == nil)
    }

    @Test func channelRendererWithoutIdOrNameIsSkipped() throws {
        #expect(ItemParser.channel(fromChannelRenderer: try json(#"{"title":{"simpleText":"x"}}"#)) == nil)
        #expect(ItemParser.channel(fromChannelRenderer: try json(#"{"channelId":"UCx"}"#)) == nil)
        #expect(ItemParser.channel(fromChannelRenderer: .null) == nil)
    }

    // MARK: Walking

    @Test func harvestStopsAtItemRenderers() throws {
        // A renderer inside another renderer's menu or metadata is not a separate result.
        let outer = try json(#"""
        {"videoId":"outer000001","title":{"simpleText":"Outer"},
         "expandableMetadata":{"expandableMetadataRenderer":{"expandedContent":{"videoRenderer":{"videoId":"inner000001","title":{"simpleText":"Inner"}}}}}}
        """#)
        #expect(ItemParser.items(in: [["videoRenderer": outer]]).map(\.id) == ["video:outer000001"])
    }

    @Test func harvestKeepsDocumentOrderAcrossWrappers() throws {
        let doc = try json(#"""
        {"contents":[
          {"richItemRenderer":{"content":{"videoRenderer":{"videoId":"aaaaaaaaaaa","title":{"simpleText":"A"}}}}},
          {"richSectionRenderer":{"content":{"richShelfRenderer":{"contents":[
            {"richItemRenderer":{"content":{"shortsLockupViewModel":{"entityId":"shorts-shelf-item-bbbbbbbbbbb","overlayMetadata":{"primaryText":{"content":"B"}}}}}},
            {"richItemRenderer":{"content":{"channelRenderer":{"channelId":"UCccc","title":{"simpleText":"C"}}}}}
          ]}}}},
          {"itemSectionRenderer":{"contents":[{"videoRenderer":{"videoId":"ddddddddddd","title":{"simpleText":"D"}}}]}},
          {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"NEXT"}}}}
        ]}
        """#)
        #expect(ItemParser.items(in: doc).map(\.id) == ["video:aaaaaaaaaaa", "video:bbbbbbbbbbb", "channel:UCccc", "video:ddddddddddd"])
    }

    @Test func harvestTakesTheLastContinuationOfTheScope() throws {
        let doc = try json(#"""
        [{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"FIRST"}}}},
         {"videoRenderer":{"videoId":"aaaaaaaaaaa","title":{"simpleText":"A"}}},
         {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"LAST"}}}}]
        """#)
        #expect(ItemParser.harvest(doc).continuation == "LAST")
        #expect(ItemParser.harvest(doc).items.count == 1)
    }

    @Test func harvestReadsBothContinuationShapes() throws {
        let renderer = try json(#"[{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"RENDERER"}}}}]"#)
        let viewModel = try json(#"[{"continuationItemViewModel":{"continuationCommand":{"innertubeCommand":{"continuationCommand":{"token":"VIEWMODEL"}}}}}]"#)
        #expect(ItemParser.harvest(renderer).continuation == "RENDERER")
        #expect(ItemParser.harvest(viewModel).continuation == "VIEWMODEL")
    }

    // MARK: YouTube's own text is kept when there is no number

    /// What YouTube sent, and the number the app may derive from it (nil: the app shows the text).
    struct CountExample: Sendable, CustomTestStringConvertible {
        var text: String
        var count: Int?
        var testDescription: String { "\(text) → \(count.map(String.init) ?? "nil")" }

        init(_ text: String, _ count: Int?) {
            self.text = text
            self.count = count
        }
    }

    private static let viewTexts: [CountExample] = [
        CountExample("2,763,792 views", 2_763_792), CountExample("810K views", 810_000), CountExample("1 view", 1), CountExample("No views", 0),
        // Other languages keep their own wording and get no number, whatever parseCount would make of them.
        CountExample("12万 回視聴", nil), CountExample("12 тыс. просмотров", nil), CountExample("12 tn visningar", nil),
        CountExample("2 763 792 vues", nil), CountExample("2.763.792 Aufrufe", nil), CountExample("110 Tsd. Aufrufe", nil),
        CountExample("2,7 jt x ditonton", nil), CountExample("12 B görüntüleme", nil),
    ]

    @Test(arguments: viewTexts)
    func videoRendererKeepsTheViewText(_ example: CountExample) throws {
        let renderer = try json(#"{"videoId":"abc","title":{"simpleText":"T"},"viewCountText":{"simpleText":"\#(example.text)"}}"#)
        let video = try #require(ItemParser.video(fromVideoRenderer: renderer))
        #expect(video.viewCountText == example.text)
        #expect(video.viewCount == example.count)
    }

    @Test(arguments: viewTexts)
    func shortsLockupKeepsTheViewText(_ example: CountExample) throws {
        let lockup = try json(#"""
        {"onTap":{"innertubeCommand":{"reelWatchEndpoint":{"videoId":"abc"}}},
         "overlayMetadata":{"primaryText":{"content":"T"},"secondaryText":{"content":"\#(example.text)"}}}
        """#)
        let video = try #require(ItemParser.short(fromShortsLockup: lockup))
        #expect(video.viewCountText == example.text)
        #expect(video.viewCount == example.count)
    }

    @Test(arguments: [
        CountExample("14 videos", 14), CountExample("1 video", 1), CountExample("8 lessons", 8), CountExample("14 Videos", 14),
        CountExample("1,2 Tsd. Videos", 1_200),
        CountExample("12 тыс. видео", nil), CountExample("12万 本の動画", nil), CountExample("1 234 vidéos", nil), CountExample("12 vídeos", nil),
    ])
    func playlistLockupKeepsTheCountText(_ example: CountExample) throws {
        let playlist = try #require(ItemParser.playlist(fromLockup: try playlistLockup(count: example.text)))
        #expect(playlist.videoCountText == example.text)
        #expect(playlist.videoCount == example.count)
    }

    @Test(arguments: ["チャンネル登録者数 125万人", "12 тыс. подписчиков", "1,25 Mio. Abonnenten", "125 k abonnés"])
    func channelRendererKeepsTheSubscriberText(_ text: String) throws {
        let renderer = try json(#"""
        {"channelId":"UCx","title":{"simpleText":"Chan"},"subscriberCountText":{"simpleText":"@chan"},
         "videoCountText":{"simpleText":"\#(text)"}}
        """#)
        let channel = try #require(ItemParser.channel(fromChannelRenderer: renderer))
        #expect(channel.subscriberCountText == text)
        #expect(channel.handle == "@chan")
    }

    @Test func harvestIgnoresContinuationsInsideSkippedBlocks() throws {
        // The "about" panel of a channel header carries a continuation too; it is not the grid's.
        let doc = try json(#"""
        [{"videoRenderer":{"videoId":"aaaaaaaaaaa","title":{"simpleText":"A"}}},
         {"engagementPanelSectionListRenderer":{"content":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[
           {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"ABOUT"}}}}]}}]}}}},
         {"adSlotRenderer":{"x":{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"AD"}}}}}}]
        """#)
        #expect(ItemParser.harvest(doc).continuation == nil)
        #expect(ItemParser.harvest(doc).items.count == 1)
    }
}
