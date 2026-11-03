import Foundation

/// Realistic fixed content for previews, `-mockServices YES` launches and tests.
///
/// Titles, ids, counts and comments come from the real responses captured in the test fixtures
/// (2026-11-03). Everything is static and `Sendable`; "published" dates are relative to the moment the data is
/// first touched, so "22 hours ago" stays true while the process runs.
public enum SampleData {
    // MARK: - Channels

    public static let blender = ChannelSummary(
        id: "UCSMOQeBJ2RAnuFungnQOxLg",
        name: "Blender",
        handle: "@BlenderOfficial",
        avatarURL: url("https://yt3.ggpht.com/ytc/AIdro_nqhez5E1j4YzrCvzTAAB6z_KDFFZznqWv0x-vfY2gsXdY=s176-c-k-c0x00ffffff-no-rj"),
        subscriberCountText: "1.25M subscribers",
        videoCountText: "1.5K videos",
        descriptionSnippet: "Official YouTube channel for Blender, the Free and Open Source 3D Creation Suite."
    )

    public static let blenderGuru = ChannelSummary(
        id: "UCOKHwx1VCdgnxwbjyb9Iu1g",
        name: "Blender Guru",
        handle: "@blenderguru",
        avatarURL: url("https://yt3.ggpht.com/DSzMBU-1G4ZvdLS6YtnItbZliceGWE2uS8VIo2jYcxEDqPtSmYIFcDk6NXgjn99qXoab06XWnw=s176-c-k-c0x00ffffff-no-rj"),
        subscriberCountText: "3.45M subscribers",
        videoCountText: nil,
        descriptionSnippet: "Hi I'm Andrew Price, and I create tutorials for the free open source 3D software \"Blender\"."
    )

    public static let rickAstley = ChannelSummary(
        id: "UCuAXFkgsw1L7xaCfnd5JJOw",
        name: "Rick Astley",
        handle: "@RickAstleyYT",
        avatarURL: url("https://yt3.ggpht.com/_ShEGOdg-t5YGJse14Ooq6FYBZqX_QSlhaTNjG06miYusm5lWm1UroLyVxnYtahADfRTVLtuVQ=s176-c-k-c0x00ffffff-no-rj"),
        subscriberCountText: "4.56M subscribers"
    )

    public static let ryanKingArt = ChannelSummary(
        id: "UCIXjev1_mJ1plJhF9lGarQg",
        name: "Ryan King Art",
        handle: "@RyanKingArt",
        avatarURL: url("https://yt3.ggpht.com/K3unDMf4w9YEgLU5Xu1eMvS_hmpAQ6Zblq9toM8-ew5SUyapRWFWUFhlRkSofYVAc2mvPEsy=s176-c-k-c0x00ffffff-no-rj")
    )

    public static let polyFilms = ChannelSummary(
        id: "UCpzUp21QjEZo_Jp7rt5w83Q",
        name: "PolyFilms",
        avatarURL: url("https://yt3.ggpht.com/epivL7bugBtE3gTAr2hWyghGDD2wdxLhUA7xDarOuoZ86raVbUv3xVoUvt1TD3f3JWQBiXCKbQ=s176-c-k-c0x00ffffff-no-rj")
    )

    public static let roBuilder = ChannelSummary(
        id: "UCl-BrQMfynC7mpPDsg6MqlQ",
        name: "RoBuilder",
        handle: "@RoBuilder",
        avatarURL: url("https://yt3.ggpht.com/2s0VA0ZAsU-8QwdmmqPMABO_eifGAvlG8YGTBnMGemXt8bV50m4Yevt3uTXiPmhfsBrupepGymo=s176-c-k-c0x00ffffff-no-rj")
    )

    public static let kevinStratvert = ChannelSummary(
        id: "UCfJT_eYDTmDE-ovKaxVE1ig",
        name: "Kevin Stratvert",
        handle: "@KevinStratvert",
        avatarURL: url("https://yt3.ggpht.com/FHaircC3fnPqOhk3M4POJQlPF2_yVnCj5W60SNbFL_zK5jzmJ5mNyFVaoLKZufC4uPo4WP8gQw=s176-c-k-c0x00ffffff-no-rj")
    )

    public static let bradsArtSchool = ChannelSummary(
        id: "UClX5lGGHeZ7OILb1ozSNtOg",
        name: "Brad's Art School",
        handle: "@BradsArtSchool",
        avatarURL: url("https://yt3.ggpht.com/ytc/AIdro_l974tjSe09zV26n1LNrhN8fO096w6jYDm1Xl3JLtCMbg=s176-c-k-c0x00ffffff-no-rj")
    )

    public static let polygonRunway = ChannelSummary(
        id: "UCGSJevmBuDyxjLLOBNaYMGA",
        name: "Polygon Runway",
        handle: "@polygonrunway",
        avatarURL: url("https://yt3.ggpht.com/ytc/AIdro_mH48THQw8AmdHrJjXrmkl1eJqv0d1QNgEu5jWqdsIafA=s176-c-k-c0x00ffffff-no-rj")
    )

    public static let jawed = ChannelSummary(
        id: "UC4QobU6STFB0P71PMvOGN5A",
        name: "jawed",
        handle: "@jawed"
    )

    /// Blender and Blender Guru first (the two the plan names), then the rest.
    public static let channels: [ChannelSummary] = [
        blender, blenderGuru, ryanKingArt, rickAstley, polyFilms, roBuilder, kevinStratvert, bradsArtSchool, polygonRunway, jawed,
    ]

    public static func channel(id: String) -> ChannelSummary? {
        channels.first { $0.id == id }
    }

    /// The Blender channel banner (about 6:1), used as the header image of every mock channel.
    public static let channelBannerURL = url("https://yt3.googleusercontent.com/6pYvl5Jl7MszRRlhjlRuEfil7B1sgt3u4WbCCl7yHPv1LbsSVAcaoGfs3gyrJUM201DQnzrUOA=w1707-fcrop64=1,00005a57ffffa5a8-k-c0xffffffff-no-nd-rj")

    // MARK: - Videos

    /// 16 videos including one Short (`gIjBeEvDXew`), in the order a search results page would list them.
    /// Thumbnails are the ytimg defaults.
    public static let videos: [VideoSummary] = [
        makeVideo("z-Xl9tGqH14", "Beginner Blender Tutorial (2026)", blenderGuru,
                  seconds: 15550, views: 2_763_792, viewsText: "2,763,792 views", published: "9 months ago", daysAgo: 270),
        makeVideo("mHrHLqQj7Ts", "Making of: The Blender Open Movies Exhibition", blender,
                  seconds: 280, views: 9_793, viewsText: "9.8K views", published: "22 hours ago", hoursAgo: 22),
        makeVideo("aqz-KE-bpKQ", "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film", blender,
                  seconds: 635, views: 23_500_582, viewsText: "23,500,582 views", published: "11 years ago",
                  date: date(2014, 11, 10)),
        makeVideo("dQw4w9WgXcQ", "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)", rickAstley,
                  seconds: 213, views: 1_833_297_545, viewsText: "1,833,297,545 views", published: "17 years ago",
                  date: date(2009, 10, 24)),
        makeVideo("jNQXAC9IVRw", "Me at the zoo", jawed,
                  seconds: 19, views: 380_000_000, viewsText: "380M views", published: "21 years ago",
                  date: date(2005, 4, 24)),
        makeVideo("7pPUE6cGFwI", "A Little Pony\u{2019}s Big Heart", polyFilms,
                  seconds: 729, views: 7_800_000, viewsText: "7.8M views", published: "13 days ago", daysAgo: 13),
        makeVideo("sgMfEq3pDE0", "Part 1 - Blender for Complete Beginners Tutorial Series (Navigation & Shortcut Keys)", ryanKingArt,
                  seconds: 1946, views: 296_000, viewsText: "296K views", published: "2 years ago", daysAgo: 730),
        makeVideo("gIjBeEvDXew", "Noob vs PRO: Realistic Clothes in Blender", nil,
                  seconds: nil, views: 810_000, viewsText: "810K views", published: nil, isShort: true),
        makeVideo("peSv5IT5Ve4", "ABSOLUTE Beginner Basics.. Blender For Noobs 2025", roBuilder,
                  seconds: 507, views: 2_057_927, viewsText: "2,057,927 views", published: "1 year ago", daysAgo: 400),
        makeVideo("sO_lhW8av3U", "Blender Conference 2026 Recap", blender,
                  seconds: 149, views: 23_000, viewsText: "23K views", published: "2 weeks ago", daysAgo: 14),
        makeVideo("Ci3Has4L5W4", "Blender Tutorial for Beginners", kevinStratvert,
                  seconds: 1986, views: 811_032, viewsText: "811,032 views", published: "1 year ago", daysAgo: 380),
        makeVideo("SVJiCL3K0j4", "The Future of Rendering \u{2014} BCON26", blender,
                  seconds: 1106, views: 28_000, viewsText: "28K views", published: "1 month ago", daysAgo: 33),
        makeVideo("nESaz92SJ0w", "The World's Easiest Blender Tutorial for Beginners", bradsArtSchool,
                  seconds: 1775, views: 880_208, viewsText: "880,208 views", published: "1 year ago", daysAgo: 420),
        makeVideo("dVrELpmfcEQ", "Blender Education Community Meeting \u{2014} BCON26", blender,
                  seconds: 7482, views: 12_000, viewsText: "12K views", published: "11 days ago", daysAgo: 11),
        makeVideo("K7__BjW4UWE", "2026 Blender 5.0 Beginner Tutorial", polygonRunway,
                  seconds: 4306, views: 297_167, viewsText: "297,167 views", published: "9 months ago", daysAgo: 280),
        makeVideo("Lxem4yMs5Dg", "Sculpting for Complete Beginners! (Blender Tutorial)", ryanKingArt,
                  seconds: 3249, views: 827_876, viewsText: "827,876 views", published: "2 years ago", daysAgo: 800),
    ]

    /// The video with this id from `videos` or `playlistVideos`.
    public static func video(id: String) -> VideoSummary? {
        videos.first { $0.id == id } ?? playlistVideos.first { $0.id == id }
    }

    /// The sample videos uploaded by a channel, newest first.
    public static func videos(forChannel channelID: String) -> [VideoSummary] {
        videos
            .filter { $0.channel?.id == channelID }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    // MARK: - Playlists

    /// "Blender for Complete Beginners Tutorial Series", 14 videos by Ryan King Art.
    public static let playlist = PlaylistSummary(
        id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B",
        title: "Blender for Complete Beginners Tutorial Series",
        channel: ryanKingArt.ref,
        thumbnails: VideoSummary.defaultThumbnails(for: "sgMfEq3pDE0"),
        videoCount: 14,
        videoCountText: "14 videos"
    )

    /// A playlist on the Blender channel's Playlists tab.
    public static let blenderPlaylist = PlaylistSummary(
        id: "PLa1F2ddGya_-I9y1nXALrBqrZNdlUE012",
        title: "Blender Conference 2026",
        channel: blender.ref,
        thumbnails: VideoSummary.defaultThumbnails(for: "SVJiCL3K0j4"),
        videoCount: 3,
        videoCountText: "3 videos"
    )

    public static let playlists: [PlaylistSummary] = [playlist, blenderPlaylist]

    /// The 14 videos of `playlist`, in order.
    public static let playlistVideos: [VideoSummary] = {
        let rows: [(id: String, title: String, seconds: Int, views: Int, text: String)] = [
            ("sgMfEq3pDE0", "Part 1 - Blender for Complete Beginners Tutorial Series (Navigation & Shortcut Keys)", 1946, 296_000, "296K views"),
            ("Wh4GGEUiNAE", "Part 2 - Blender for Complete Beginners Tutorial Series (User Interface & Edit Mode)", 1815, 92_000, "92K views"),
            ("6vQq9yS3Np8", "Part 3 - Blender for Complete Beginners Tutorial Series (Outliner & Modeling Snowballs)", 2508, 72_000, "72K views"),
            ("KrM7Wh32lEM", "Part 4 - Blender for Complete Beginners Tutorial Series (Modeling Parts of the Snowman)", 1934, 53_000, "53K views"),
            ("IGf7Ex5Ig_I", "Part 5 - Blender for Complete Beginners Tutorial Series (Modeling the Buttons & Using Curves)", 1015, 38_000, "38K views"),
            ("0bNtSUm1GUg", "Part 6 - Blender for Complete Beginners Tutorial Series (Cloth Physics & Scarf)", 936, 35_000, "35K views"),
            ("bR6q6rpXCKQ", "Part 7 - Blender for Complete Beginners Tutorial Series (Basics of Materials)", 1850, 26_000, "26K views"),
            ("KJUWhT8iwtk", "Part 8 - Blender for Complete Beginners Tutorial Series (UV Unwrapping)", 1123, 24_000, "24K views"),
            ("7PjIiYs93hU", "Part 9 - Blender for Complete Beginners Tutorial Series (Texturing Objects)", 1687, 25_000, "25K views"),
            ("mDRr7n6Bejw", "Part 10 - Blender for Complete Beginners Tutorial Series (Lighting & Render Engines)", 2339, 18_000, "18K views"),
            ("1j-q4jJYv6Q", "Part 11 - Blender for Complete Beginners Tutorial Series (Procedural Materials)", 1072, 13_000, "13K views"),
            ("eT-s5W_7jvw", "Part 12 - Blender for Complete Beginners Tutorial Series (Particle Systems)", 715, 13_000, "13K views"),
            ("JDGX9wwPt8Q", "Part 13 - Blender for Complete Beginners Tutorial Series (Camera and Scene Setup)", 864, 12_000, "12K views"),
            ("J5dIOfaZdYE", "Part 14 - Blender for Complete Beginners Tutorial Series (Rendering & Compositing)", 1549, 15_000, "15K views"),
        ]
        return rows.map { row in
            makeVideo(row.id, row.title, ryanKingArt, seconds: row.seconds, views: row.views, viewsText: row.text,
                      published: "2 years ago", daysAgo: 730)
        }
    }()

    // MARK: - Comments, chapters, SponsorBlock, captions

    /// Five comments on Big Buck Bunny, as captured in the fixtures. The first is marked pinned and the fourth
    /// hearted so the UI can show those badges.
    public static let comments: [Comment] = [
        Comment(
            id: "UgxNivqkidvk9k_eR_B4AaABAg",
            authorName: "@randomthef1rst",
            authorAvatarURL: url("https://yt3.ggpht.com/ubgmtF11RqDgBJYwvOKQwKBSHzcbGNVtM4g-R_tX-LvaUQ0wbdR5UzFFtDTeVckFZCRlKy6B-A=s88-c-k-c0x00ffffff-no-rj"),
            authorChannelID: "UCImHhAGbOH3pdLQ_VU2RZpQ",
            text: "Here after that one TikTok edit",
            publishedText: "1 year ago",
            likeCountText: "790",
            replyCount: 25,
            repliesContinuation: "mock-replies:UgxNivqkidvk9k_eR_B4AaABAg",
            isPinned: true
        ),
        Comment(
            id: "Ugyy2G5xdRISEhCQmNZ4AaABAg",
            authorName: "@Seed",
            authorAvatarURL: url("https://yt3.ggpht.com/DutO7BrOLqM-GaGSI4QYsdAWQsu-fqTbWjDOVn_AU4twNV_AXdQ1yslLjtkXbqow8wqd6fyt=s88-c-k-c0x00ffffff-no-rj"),
            authorChannelID: "UCP2mYGClL3KjKzSrMgLytfw",
            text: "Ah.. The classic test video",
            publishedText: "2 years ago",
            likeCountText: "1.9K",
            replyCount: 14,
            repliesContinuation: "mock-replies:Ugyy2G5xdRISEhCQmNZ4AaABAg"
        ),
        Comment(
            id: "UgzU6VF1ghyO-uTozEx4AaABAg",
            authorName: "@Zanderbolt-js4fv",
            authorAvatarURL: url("https://yt3.ggpht.com/ytc/AIdro_nCJ3E0dAHfOG0RUOmbmLskUNWyWkyXj-cBNc-OsJkUuUo=s88-c-k-c0x00ffffff-no-rj"),
            authorChannelID: "UC2mKN60lvo0o-8Imm7v88Kg",
            text: "Wait,is that..............BIG CHUNGUS?!",
            publishedText: "7 years ago",
            likeCountText: "757",
            replyCount: 12,
            repliesContinuation: "mock-replies:UgzU6VF1ghyO-uTozEx4AaABAg"
        ),
        Comment(
            id: "UgzrXz18R8jmeI5i-el4AaABAg",
            authorName: "@BergsArt",
            authorAvatarURL: url("https://yt3.ggpht.com/gA_SNJ4jZVwl3Z37tajx18quPy7qCS-djBKkoI32F4WEqIcOUJ4B_H3EPj5YdLNP94Z7CuNYTw=s88-c-k-c0x00ffffff-no-rj"),
            authorChannelID: "UCK40BkhHK2_YfdRZHuqJaqQ",
            text: "Comments\n90% - Big Chungus\n9% - Remembering this as a kid\n1% - This short was made using free software",
            publishedText: "7 years ago",
            likeCountText: "2.7K",
            replyCount: 21,
            repliesContinuation: "mock-replies:UgzrXz18R8jmeI5i-el4AaABAg",
            isHearted: true
        ),
        Comment(
            id: "Ugwdq02hAYunpItTEq54AaABAg",
            authorName: "@sergddr",
            authorAvatarURL: url("https://yt3.ggpht.com/ytc/AIdro_n4U4z0viIeq0FxaF2mlxL23ytyCTL-1eZ0Ma3C4QzVoAo=s88-c-k-c0x00ffffff-no-rj"),
            authorChannelID: "UCOEzdoFB9UZc_b8lsMmoLqA",
            text: "Big Chungus: Story mode",
            publishedText: "7 years ago",
            likeCountText: "2.6K",
            replyCount: 45,
            repliesContinuation: "mock-replies:Ugwdq02hAYunpItTEq54AaABAg"
        ),
    ]

    /// A second page of comments (invented, for exercising infinite scroll).
    public static let moreComments: [Comment] = [
        Comment(id: "UgxMockMore1.mock", authorName: "@bunny_fan_2014", text: "Watched this on a school projector back in the day.",
                publishedText: "3 years ago", likeCountText: "310"),
        Comment(id: "UgxMockMore2.mock", authorName: "@render_farm_dave", text: "60 fps makes the fur look unreal.",
                publishedText: "4 years ago", likeCountText: "128"),
        Comment(id: "UgxMockMore3.mock", authorName: "@blendernewbie", text: "Started learning Blender because of this.",
                publishedText: "5 years ago", likeCountText: "96"),
    ]

    /// Replies to any comment (invented).
    public static let replies: [Comment] = [
        Comment(id: "UgxMockReply1.mock", authorName: "@Seed", text: "Same here, nothing else comes close.",
                publishedText: "1 year ago", likeCountText: "12"),
        Comment(id: "UgxMockReply2.mock", authorName: "@sergddr", text: "Haha yes, a true classic.",
                publishedText: "11 months ago", likeCountText: "4"),
        Comment(id: "UgxMockReply3.mock", authorName: "@Zanderbolt-js4fv", text: "Okay but the chinchillas are the real stars.",
                publishedText: "2 weeks ago"),
    ]

    /// Three chapters at 0, 60 and 120 seconds.
    public static let chapters: [Chapter] = [
        Chapter(title: "Introduction", startSeconds: 0),
        Chapter(title: "The main part", startSeconds: 60),
        Chapter(title: "Wrap-up", startSeconds: 120),
    ]

    /// A sponsor segment at 30-45 s and a self-promotion segment at 120-130 s.
    public static let segments: [SponsorSegment] = [
        SponsorSegment(id: "e366ae05-5f2c-4c1e-9d0d-0a1b2c3d4e51", category: .sponsor, actionType: .skip, start: 30, end: 45),
        SponsorSegment(id: "b1f0c2d3-7a44-4a3b-8c55-9e8d7c6b5a42", category: .selfpromo, actionType: .skip, start: 120, end: 130),
    ]

    /// English captions: a manual track and an auto-generated one.
    public static func captionTracks(for videoID: String) -> [CaptionTrack] {
        let base = "https://www.youtube.com/api/timedtext?v=\(videoID)&lang=en"
        return [
            url(base).map { CaptionTrack(languageCode: "en", name: "English", baseURL: $0) },
            url(base + "&kind=asr").map { CaptionTrack(languageCode: "en", name: "English (auto-generated)", baseURL: $0, isAutoGenerated: true) },
        ].compactMap { $0 }
    }

    /// The first cues of the Rick Astley captions fixture.
    public static let captionCues: [CaptionCue] = [
        CaptionCue(start: 1.36, end: 3.04, text: "[\u{266A}\u{266A}\u{266A}]"),
        CaptionCue(start: 18.64, end: 21.88, text: "\u{266A} We're no strangers to love \u{266A}"),
        CaptionCue(start: 22.64, end: 26.96, text: "\u{266A} You know the rules\nand so do I \u{266A}"),
        CaptionCue(start: 27.04, end: 31.04, text: "\u{266A} A full commitment's\nwhat I'm thinking of \u{266A}"),
        CaptionCue(start: 31.12, end: 35.08, text: "\u{266A} You wouldn't get this\nfrom any other guy \u{266A}"),
        CaptionCue(start: 35.16, end: 39.52, text: "\u{266A} I just wanna tell you\nhow I'm feeling \u{266A}"),
        CaptionCue(start: 40.52, end: 42.92, text: "\u{266A} Gotta make you understand \u{266A}"),
    ]

    /// The community title DeArrow would offer for `dQw4w9WgXcQ`.
    public static let betterTitleForRickroll = "Rick Astley - Never gonna give you up (official music video)"

    // MARK: - Watch page and streams

    /// Apple's public bipbop HLS test stream, used as the playable source for every mock video.
    public static let bipbopHLSURL = url("https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")

    /// The watch page for `video`: description with links, chapters (for videos of three minutes or more), comments
    /// token and up to ten related videos (a Short is among them, so the filter has something to remove).
    public static func details(for video: VideoSummary) -> VideoDetails {
        let channelRef = video.channel ?? blender.ref
        let hasChapters = !video.isShort && (video.durationSeconds ?? 0) >= 180
        let related = videos.filter { $0.id != video.id }

        var likeCount = (video.viewCount ?? 0) / 25
        var likeCountText: String? = likeCount > 0 ? shortCountText(likeCount) : nil
        if video.id == "aqz-KE-bpKQ" {
            likeCount = 110_000
            likeCountText = "110K"
        }

        return VideoDetails(
            id: video.id,
            title: video.title,
            channel: channelRef,
            subscriberCountText: channel(id: channelRef.id)?.subscriberCountText,
            viewCount: video.viewCount,
            viewCountText: video.viewCountText,
            shortViewCountText: video.viewCount.map { shortCountText($0) + " views" },
            dateText: video.publishedAt.map(absoluteDateText),
            relativeDateText: video.publishedText,
            likeCount: likeCount > 0 ? likeCount : nil,
            likeCountText: likeCountText,
            description: descriptionText(for: video, hasChapters: hasChapters),
            chapters: hasChapters ? chapters : [],
            commentCountText: "5,222",
            commentsContinuation: "mock-comments:\(video.id):top",
            related: Array(related.prefix(relatedPageSize)),
            relatedContinuation: related.count > relatedPageSize ? "mock-related:\(video.id):1" : nil,
            isLive: video.isLive
        )
    }

    /// How many related videos the first page of `details(for:)` holds.
    public static let relatedPageSize = 10

    /// Playable sources for `videoID`: the bipbop HLS URL and no downloadable formats, valid for 21540 seconds.
    public static func streamInfo(for videoID: String, now: Date = Date()) -> StreamInfo {
        let video = self.video(id: videoID)
        return StreamInfo(
            videoID: videoID,
            title: video?.title ?? "Sample video",
            author: video?.channel?.name ?? blender.name,
            channelID: video?.channel?.id ?? blender.id,
            lengthSeconds: video?.durationSeconds ?? 213,
            viewCount: video?.viewCount,
            shortDescription: video.map { "Sample description for \($0.title)." },
            thumbnails: video?.displayThumbnails ?? VideoSummary.defaultThumbnails(for: videoID),
            isLive: false,
            hlsURL: bipbopHLSURL,
            formats: [],
            captions: captionTracks(for: videoID),
            expiresAt: now.addingTimeInterval(21_540)
        )
    }

    // MARK: - Internals

    private static let reference = Date()

    private static func url(_ string: String) -> URL? {
        URL(string: string)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? reference
    }

    private static func makeVideo(
        _ id: String,
        _ title: String,
        _ channel: ChannelSummary?,
        seconds: Int?,
        views: Int?,
        viewsText: String?,
        published: String?,
        daysAgo: Double? = nil,
        hoursAgo: Double? = nil,
        date: Date? = nil,
        isShort: Bool = false
    ) -> VideoSummary {
        let publishedAt: Date? = date
            ?? daysAgo.map { reference.addingTimeInterval(-$0 * 86_400) }
            ?? hoursAgo.map { reference.addingTimeInterval(-$0 * 3_600) }
        return VideoSummary(
            id: id,
            title: title,
            channel: channel?.ref,
            thumbnails: VideoSummary.defaultThumbnails(for: id),
            durationSeconds: seconds,
            viewCount: views,
            viewCountText: viewsText,
            publishedText: published,
            publishedAt: publishedAt,
            isShort: isShort
        )
    }

    /// YouTube-style short count: 9793 -> "9.8K", 23_500_582 -> "23M", 7_800_000 -> "7.8M".
    private static func shortCountText(_ count: Int) -> String {
        let units: [(size: Double, suffix: String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        for unit in units where Double(count) >= unit.size {
            let value = Double(count) / unit.size
            if value < 10 {
                let tenths = Int((value * 10).rounded())
                return tenths % 10 == 0 ? "\(tenths / 10)\(unit.suffix)" : "\(tenths / 10).\(tenths % 10)\(unit.suffix)"
            }
            return "\(Int(value))\(unit.suffix)"
        }
        return String(count)
    }

    private static func absoluteDateText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "en_US"), timeZone: .gmt))
    }

    private static func descriptionText(for video: VideoSummary, hasChapters: Bool) -> AttributedDescription {
        if video.id == "aqz-KE-bpKQ" {
            return attributed([
                ("UHD High Frame rate version of the iconic short film by Blender, Big Buck Bunny. More info:  ", nil),
                ("https://studio.blender.org/projects/b...", url("https://studio.blender.org/projects/big-buck-bunny/").map { .url($0) }),
                ("\n\nLearn more about this UHD high frame-rate version at: ", nil),
                ("http://bbb3d.renderfarming.net", url("http://bbb3d.renderfarming.net").map { .url($0) }),
            ])
        }
        var parts: [(String, DescriptionLink.Target?)] = [("Sample description for \u{201C}\(video.title)\u{201D}.\n\n", nil)]
        if hasChapters {
            parts += [
                ("Chapters:\n", nil),
                ("0:00", .timestamp(seconds: 0)), (" Introduction\n", nil),
                ("1:00", .timestamp(seconds: 60)), (" The main part\n", nil),
                ("2:00", .timestamp(seconds: 120)), (" Wrap-up\n\n", nil),
            ]
        }
        parts += [
            ("More at ", nil),
            ("https://www.blender.org", url("https://www.blender.org").map { .url($0) }),
            ("\n", nil),
            ("#blender", .hashtag("blender")),
            (" ", nil),
            ("#sample", .hashtag("sample")),
        ]
        return attributed(parts)
    }

    /// Joins the parts and records the UTF-16 range of every part that carries a link target.
    private static func attributed(_ parts: [(text: String, target: DescriptionLink.Target?)]) -> AttributedDescription {
        var text = ""
        var links: [DescriptionLink] = []
        var offset = 0
        for part in parts {
            let length = part.text.utf16.count
            if let target = part.target {
                links.append(DescriptionLink(range: offset..<(offset + length), target: target))
            }
            text += part.text
            offset += length
        }
        return AttributedDescription(text: text, links: links)
    }
}
