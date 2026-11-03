import Foundation
import Testing
@testable import NoSlopKit

@Suite struct SampleDataTests {
    @Test func hasTheVideosThePlanNames() {
        let ids = SampleData.videos.map(\.id)
        #expect(SampleData.videos.count >= 12)
        #expect(Set(ids).count == ids.count, "video ids must be unique")
        for required in ["z-Xl9tGqH14", "mHrHLqQj7Ts", "aqz-KE-bpKQ", "dQw4w9WgXcQ", "jNQXAC9IVRw", "7pPUE6cGFwI", "sgMfEq3pDE0", "gIjBeEvDXew"] {
            #expect(ids.contains(required), "\(required)")
        }
    }

    @Test func hasExactlyOneShort() {
        let shorts = SampleData.videos.filter(\.isShort)
        #expect(shorts.map(\.id) == ["gIjBeEvDXew"])
        #expect(shorts.first?.title == "Noob vs PRO: Realistic Clothes in Blender")
    }

    @Test func videosCarryFixtureValues() throws {
        let tutorial = try #require(SampleData.video(id: "z-Xl9tGqH14"))
        #expect(tutorial.title == "Beginner Blender Tutorial (2026)")
        #expect(tutorial.durationSeconds == 15_550)
        #expect(tutorial.viewCount == 2_763_792 && tutorial.viewCountText == "2,763,792 views")
        #expect(tutorial.channel?.name == "Blender Guru" && tutorial.channel?.id == "UCOKHwx1VCdgnxwbjyb9Iu1g")
        #expect(tutorial.publishedText == "9 months ago")

        let bunny = try #require(SampleData.video(id: "aqz-KE-bpKQ"))
        #expect(bunny.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(bunny.durationSeconds == 635 && bunny.viewCount == 23_500_582)
        #expect(bunny.channel?.id == "UCSMOQeBJ2RAnuFungnQOxLg")
    }

    @Test func nonShortVideosAreFullyPopulated() {
        for video in SampleData.videos where !video.isShort {
            #expect(video.channel != nil, "\(video.id) has a channel")
            #expect(video.durationSeconds != nil, "\(video.id) has a duration")
            #expect(video.viewCount != nil && video.viewCountText != nil, "\(video.id) has views")
            #expect(video.publishedText != nil && video.publishedAt != nil, "\(video.id) has a date")
            #expect(video.displayThumbnails.map(\.width) == [320, 480, 640], "\(video.id) thumbnails ascend")
        }
    }

    @Test func publishedDatesAreNeverInTheFuture() {
        for video in SampleData.videos + SampleData.playlistVideos {
            if let date = video.publishedAt { #expect(date <= Date(), "\(video.id)") }
        }
    }

    @Test func hasTheTwoPlannedChannels() throws {
        let blender = try #require(SampleData.channel(id: "UCSMOQeBJ2RAnuFungnQOxLg"))
        #expect(blender.name == "Blender" && blender.handle == "@BlenderOfficial" && blender.subscriberCountText == "1.25M subscribers")
        let guru = try #require(SampleData.channel(id: "UCOKHwx1VCdgnxwbjyb9Iu1g"))
        #expect(guru.name == "Blender Guru" && guru.handle == "@blenderguru")
        #expect(Set(SampleData.channels.map(\.id)).count == SampleData.channels.count)
        #expect(SampleData.channel(id: "nope") == nil)
    }

    @Test func everyVideoChannelIsAKnownChannel() {
        let known = Set(SampleData.channels.map(\.id))
        for video in SampleData.videos + SampleData.playlistVideos {
            if let channel = video.channel { #expect(known.contains(channel.id), "\(video.id)") }
        }
    }

    @Test func channelUploadsAreNewestFirst() {
        let uploads = SampleData.videos(forChannel: "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(uploads.first?.id == "mHrHLqQj7Ts")
        #expect(uploads.count >= 4)
        #expect(uploads.compactMap(\.publishedAt) == uploads.compactMap(\.publishedAt).sorted(by: >))
        #expect(SampleData.videos(forChannel: "nope").isEmpty)
    }

    @Test func hasThePlaylist() {
        #expect(SampleData.playlist.id == "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        #expect(SampleData.playlist.title == "Blender for Complete Beginners Tutorial Series")
        #expect(SampleData.playlistVideos.count == 14)
        #expect(SampleData.playlistVideos.first?.id == "sgMfEq3pDE0")
        #expect(SampleData.playlist.videoCount == SampleData.playlistVideos.count)
        #expect(SampleData.video(id: "Wh4GGEUiNAE")?.title.hasPrefix("Part 2") == true)
    }

    @Test func hasFiveCommentsThreeChaptersAndTwoSegments() {
        #expect(SampleData.comments.count == 5)
        #expect(Set(SampleData.comments.map(\.id)).count == 5)
        #expect(SampleData.comments.allSatisfy { !$0.text.isEmpty && !$0.authorName.isEmpty })
        #expect(SampleData.comments.first?.id == "UgxNivqkidvk9k_eR_B4AaABAg")

        #expect(SampleData.chapters.count == 3)
        #expect(SampleData.chapters.map(\.startSeconds) == [0, 60, 120])

        #expect(SampleData.segments.count == 2)
        let sponsor = SampleData.segments[0]
        #expect(sponsor.category == .sponsor && sponsor.start == 30 && sponsor.end == 45)
        let selfPromo = SampleData.segments[1]
        #expect(selfPromo.category == .selfpromo && selfPromo.start == 120 && selfPromo.end == 130)
    }

    @Test func detailsForTheBigBuckBunnyUseTheRealDescription() throws {
        let video = try #require(SampleData.video(id: "aqz-KE-bpKQ"))
        let details = SampleData.details(for: video)
        #expect(details.title == video.title)
        #expect(details.channel.id == "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(details.subscriberCountText == "1.25M subscribers")
        #expect(details.shortViewCountText == "23M views")
        #expect(details.dateText == "Nov 10, 2014")
        #expect(details.relativeDateText == "11 years ago")
        #expect(details.likeCountText == "110K")
        #expect(details.description.text.hasPrefix("UHD High Frame rate version"))
        #expect(details.description.links.count == 2)
        #expect(details.chapters.count == 3)
        #expect(details.commentsContinuation != nil)
        #expect(!details.isLive)
    }

    @Test func descriptionLinkRangesPointAtTheLinkText() throws {
        for video in SampleData.videos where !video.isShort {
            let description = SampleData.details(for: video).description
            let units = Array(description.text.utf16)
            #expect(!description.links.isEmpty, "\(video.id)")
            for link in description.links {
                #expect(link.range.lowerBound >= 0 && link.range.upperBound <= units.count, "\(video.id)")
                let covered = String(decoding: units[link.range], as: UTF16.self)
                switch link.target {
                case .hashtag(let tag): #expect(covered == "#\(tag)", "\(video.id)")
                case .timestamp(let seconds): #expect(covered == DurationFormatter.string(seconds: seconds), "\(video.id)")
                case .url: #expect(covered.hasPrefix("http"), "\(video.id)")
                default: break
                }
            }
        }
    }

    @Test func detailsListRelatedVideosWithMoreToLoad() throws {
        let video = try #require(SampleData.video(id: "dQw4w9WgXcQ"))
        let details = SampleData.details(for: video)
        #expect(details.related.count == SampleData.relatedPageSize)
        #expect(!details.related.contains { $0.id == video.id })
        #expect(details.relatedContinuation != nil)
    }

    @Test func detailsHaveChaptersOnlyForVideosOfThreeMinutesOrMore() throws {
        #expect(SampleData.details(for: try #require(SampleData.video(id: "dQw4w9WgXcQ"))).chapters.count == 3)
        #expect(SampleData.details(for: try #require(SampleData.video(id: "jNQXAC9IVRw"))).chapters.isEmpty)
        #expect(SampleData.details(for: try #require(SampleData.video(id: "gIjBeEvDXew"))).chapters.isEmpty)
    }

    @Test func streamInfoUsesTheBipbopStreamAndNoFormats() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let info = SampleData.streamInfo(for: "aqz-KE-bpKQ", now: now)
        #expect(info.hlsURL?.absoluteString == "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")
        #expect(info.formats.isEmpty)
        #expect(info.videoID == "aqz-KE-bpKQ" && info.lengthSeconds == 635 && info.author == "Blender")
        #expect(info.expiresAt == now.addingTimeInterval(21_540))
        #expect(!info.isExpired(now: now))
        #expect(info.captions.map(\.languageCode) == ["en", "en"])
        #expect(info.captions.map(\.isAutoGenerated) == [false, true])
        #expect(Set(info.captions.map(\.id)).count == 2)
    }

    @Test func streamInfoForAnUnknownVideoStillPlays() {
        let info = SampleData.streamInfo(for: "zzzzzzzzzzz")
        #expect(info.hlsURL != nil)
        #expect(info.videoID == "zzzzzzzzzzz")
    }
}

@Suite struct MockServicesTests {
    private let youTube = MockYouTubeService(delay: .zero)

    // MARK: Search

    @Test func searchReturnsAMixedFirstPageAndMore() async throws {
        let page = try await youTube.search(query: "blender", filter: SearchFilter())
        #expect(page.items.count == 10)
        #expect(page.continuation != nil)
        #expect(page.items.contains { if case .channel = $0 { true } else { false } })
        #expect(page.items.contains { if case .playlist = $0 { true } else { false } })
        #expect(Set(page.items.map(\.id)).count == page.items.count)
    }

    @Test func searchPagesNeverRepeatAnItem() async throws {
        var seen: [String] = []
        var page = try await youTube.search(query: "blender", filter: SearchFilter())
        seen += page.items.map(\.id)
        var pages = 1
        while let token = page.continuation {
            page = try await youTube.searchMore(continuation: token)
            seen += page.items.map(\.id)
            pages += 1
            #expect(pages < 10, "paging must terminate")
        }
        #expect(pages >= 2)
        #expect(Set(seen).count == seen.count)
        #expect(seen.contains("video:gIjBeEvDXew"), "the Short is part of the results so the filter has work to do")
    }

    @Test func searchHonoursTheTypeFilter() async throws {
        let videos = try await youTube.search(query: "x", filter: SearchFilter(type: .video))
        #expect(videos.items.allSatisfy { $0.video != nil })
        let channels = try await youTube.search(query: "x", filter: SearchFilter(type: .channel))
        #expect(channels.items.allSatisfy { if case .channel = $0 { true } else { false } } && !channels.items.isEmpty)
        let playlists = try await youTube.search(query: "x", filter: SearchFilter(type: .playlist))
        #expect(playlists.items.allSatisfy { if case .playlist = $0 { true } else { false } } && !playlists.items.isEmpty)
    }

    @Test func searchHonoursSortDurationAndDate() async throws {
        let byViews = try await youTube.search(query: "x", filter: SearchFilter(type: .video, sort: .viewCount))
        let views = byViews.items.compactMap(\.video).compactMap(\.viewCount)
        #expect(views == views.sorted(by: >))

        let byDate = try await youTube.search(query: "x", filter: SearchFilter(type: .video, sort: .uploadDate))
        let dates = byDate.items.compactMap(\.video).compactMap(\.publishedAt)
        #expect(dates == dates.sorted(by: >))

        let long = try await youTube.search(query: "x", filter: SearchFilter(type: .video, duration: .long))
        #expect(long.items.compactMap(\.video).allSatisfy { ($0.durationSeconds ?? 0) > 1200 } && !long.items.isEmpty)

        let today = try await youTube.search(query: "x", filter: SearchFilter(type: .video, uploadDate: .today))
        #expect(today.items.compactMap(\.video).map(\.id) == ["mHrHLqQj7Ts"])
    }

    @Test func searchMoreWithAnUnknownTokenIsAnEmptyPage() async throws {
        let page = try await youTube.searchMore(continuation: "garbage")
        #expect(page.items.isEmpty && page.continuation == nil)
    }

    @Test func suggestionsEchoTheQuery() async throws {
        let suggestions = try await youTube.suggestions(for: " Blender ")
        #expect(suggestions.first == "blender")
        #expect(suggestions.count >= 5)
        #expect(suggestions.allSatisfy { $0.hasPrefix("blender") })
        #expect(try await youTube.suggestions(for: "  ").isEmpty)
    }

    // MARK: Watch page

    @Test func videoDetailsAndRelatedPaging() async throws {
        let details = try await youTube.videoDetails(id: "aqz-KE-bpKQ")
        #expect(details.title.hasPrefix("Big Buck Bunny"))
        let token = try #require(details.relatedContinuation)
        let more = try await youTube.moreRelated(continuation: token)
        #expect(!more.items.isEmpty)
        let ids = (details.related + more.items).map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(!ids.contains("aqz-KE-bpKQ"))
        #expect(try await youTube.moreRelated(continuation: "garbage").items.isEmpty)
    }

    @Test func videoDetailsForAnUnknownIdStillWork() async throws {
        let details = try await youTube.videoDetails(id: "zzzzzzzzzzz")
        #expect(details.id == "zzzzzzzzzzz")
        #expect(!details.title.isEmpty)
    }

    @Test func commentsPagesAndReplies() async throws {
        let details = try await youTube.videoDetails(id: "aqz-KE-bpKQ")
        let first = try await youTube.comments(continuation: try #require(details.commentsContinuation))
        #expect(first.comments.count == 5)
        #expect(first.totalCountText == "5,222 Comments")
        #expect(first.sortOptions.map(\.title) == ["Top", "Newest"])
        #expect(first.sortOptions.filter(\.isSelected).map(\.title) == ["Top"])

        let newest = try await youTube.comments(continuation: try #require(first.sortOptions.last?.continuation))
        #expect(newest.comments.map(\.id) == Array(first.comments.map(\.id).reversed()))
        #expect(newest.sortOptions.filter(\.isSelected).map(\.title) == ["Newest"])

        let more = try await youTube.comments(continuation: try #require(first.continuation))
        #expect(more.comments.count == 3)
        #expect(more.continuation == nil)

        let replies = try await youTube.comments(continuation: try #require(first.comments.first?.repliesContinuation))
        #expect(!replies.comments.isEmpty)
        #expect(replies.comments.allSatisfy { $0.replyCount == 0 })

        #expect(try await youTube.comments(continuation: "garbage").comments.isEmpty)
    }

    // MARK: Channels and playlists

    @Test func channelPage() async throws {
        let page = try await youTube.channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(page.header.name == "Blender" && page.header.handle == "@BlenderOfficial")
        #expect(page.header.subscriberCountText == "1.25M subscribers" && page.header.videoCountText == "1.5K videos")
        #expect(page.header.bannerURL != nil && page.header.avatarURL != nil)
        #expect(page.availableTabs == [.videos, .live, .playlists])
        #expect(page.videos.items.compactMap(\.video).allSatisfy { $0.channel?.id == "UCSMOQeBJ2RAnuFungnQOxLg" })
        #expect(page.videos.items.first?.video?.id == "mHrHLqQj7Ts")
    }

    @Test func unknownChannelStillGetsAPage() async throws {
        let page = try await youTube.channel(id: "UCunknownunknownunknownun")
        #expect(page.header.id == "UCunknownunknownunknownun")
        #expect(!page.videos.items.isEmpty)
    }

    @Test func channelTabs() async throws {
        let id = "UCSMOQeBJ2RAnuFungnQOxLg"
        #expect(try await youTube.channelTab(channelID: id, tab: .videos).items.count >= 4)
        #expect(try await youTube.channelTab(channelID: id, tab: .live).items.isEmpty)
        let playlists = try await youTube.channelTab(channelID: id, tab: .playlists)
        #expect(playlists.items.map(\.id) == ["playlist:PLa1F2ddGya_-I9y1nXALrBqrZNdlUE012"])
        #expect(try await youTube.channelMore(continuation: "x").items.isEmpty)
    }

    @Test func playlistPages() async throws {
        let page = try await youTube.playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")
        #expect(page.info.title == "Blender for Complete Beginners Tutorial Series")
        #expect(page.videos.items.count == 10)
        let token = try #require(page.videos.continuation)
        let rest = try await youTube.playlistMore(continuation: token)
        #expect(rest.items.count == 4 && rest.continuation == nil)
        #expect((page.videos.items + rest.items).map(\.id) == SampleData.playlistVideos.map(\.id))
        #expect(try await youTube.playlistMore(continuation: "garbage").items.isEmpty)
    }

    // MARK: URL resolving

    @Test(arguments: [
        ("noslop://watch?v=dQw4w9WgXcQ", ResolvedURL.video(id: "dQw4w9WgXcQ", startSeconds: nil)),
        ("noslop://watch?v=dQw4w9WgXcQ&t=10", .video(id: "dQw4w9WgXcQ", startSeconds: 10)),
        ("noslop://channel/UCSMOQeBJ2RAnuFungnQOxLg", .channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")),
        ("noslop://playlist/PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B", .playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")),
        ("noslop://search?q=blender%20donut", .search(query: "blender donut")),
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s", .video(id: "dQw4w9WgXcQ", startSeconds: 42)),
        ("https://youtu.be/dQw4w9WgXcQ?t=1m5s", .video(id: "dQw4w9WgXcQ", startSeconds: 65)),
        ("https://m.youtube.com/watch?v=jNQXAC9IVRw", .video(id: "jNQXAC9IVRw", startSeconds: nil)),
        ("https://www.youtube.com/shorts/gIjBeEvDXew", .video(id: "gIjBeEvDXew", startSeconds: nil)),
        ("https://www.youtube.com/channel/UCSMOQeBJ2RAnuFungnQOxLg", .channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")),
        ("https://www.youtube.com/playlist?list=PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B", .playlist(id: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")),
        ("https://www.youtube.com/@BlenderOfficial", .channel(id: "UCSMOQeBJ2RAnuFungnQOxLg")),
    ])
    func resolvesLinks(link: String, expected: ResolvedURL) async throws {
        let resolved = try await youTube.resolve(url: try #require(URL(string: link)))
        #expect(resolved == expected)
    }

    @Test(arguments: ["https://example.com/watch?v=x", "noslop://unknown/thing", "noslop://watch", "https://www.youtube.com/feed/trending"])
    func ignoresLinksItDoesNotKnow(link: String) async throws {
        #expect(try await youTube.resolve(url: try #require(URL(string: link))) == nil)
    }

    // MARK: Other services

    @Test func streamResolverReturnsHLS() async throws {
        let info = try await MockStreamResolver(delay: .zero).streamInfo(videoID: "dQw4w9WgXcQ")
        #expect(info.hlsURL?.host == "devstreaming-cdn.apple.com")
        #expect(info.formats.isEmpty)
        #expect(!info.isExpired())
    }

    @Test func captionsReturnCues() async throws {
        let track = try #require(SampleData.captionTracks(for: "dQw4w9WgXcQ").first)
        let cues = try await MockCaptions(delay: .zero).cues(for: track)
        #expect(cues.first == CaptionCue(start: 1.36, end: 3.04, text: "[\u{266A}\u{266A}\u{266A}]"))
        #expect(cues.map(\.start) == cues.map(\.start).sorted())
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func rssReturnsTheChannelsUploads() async throws {
        let videos = try await MockRSSFeed(delay: .zero).latestVideos(channelID: "UCSMOQeBJ2RAnuFungnQOxLg")
        #expect(videos.first?.id == "mHrHLqQj7Ts")
        #expect(videos.allSatisfy { $0.channel?.id == "UCSMOQeBJ2RAnuFungnQOxLg" })
    }

    @Test func sponsorBlockReturnsTheTwoSegmentsForAnyVideo() async throws {
        let segments = try await MockSponsorBlock(delay: .zero).segments(videoID: "whatever")
        #expect(segments == SampleData.segments)
    }

    @Test func deArrowHasATitleOnlyForTheRickroll() async {
        let deArrow = MockDeArrow(delay: .zero)
        #expect(await deArrow.betterTitle(videoID: "dQw4w9WgXcQ") == "Rick Astley - Never gonna give you up (official music video)")
        #expect(await deArrow.betterTitle(videoID: "aqz-KE-bpKQ") == nil)
    }

    @MainActor private final class NoWebAuthenticator: WebAuthenticating {
        func authenticate(url: URL, callbackScheme: String) async throws -> URL { url }
    }

    @Test func authSignsInAndOut() async throws {
        let auth = MockAuth(delay: .zero)
        #expect(await auth.currentAccount() == nil)
        await #expect(throws: NoSlopError.notSignedIn) { _ = try await auth.accessToken() }

        let authenticator = NoWebAuthenticator()
        let account = try await auth.signIn(clientID: "123-abc.apps.googleusercontent.com", authenticator: authenticator)
        #expect(account == GoogleAccount(id: "mock", email: "you@example.com", name: "You"))
        #expect(await auth.currentAccount() == account)
        #expect(try await auth.accessToken().isEmpty == false)

        await auth.signOut()
        #expect(await auth.currentAccount() == nil)
    }

    @Test func authCanStartSignedIn() async {
        #expect(await MockAuth(delay: .zero, signedIn: true).currentAccount()?.id == "mock")
    }

    @Test func accountServiceKeepsSubscriptionsAndRatings() async throws {
        let account = MockAccountService(delay: .zero)
        let initial = try await account.subscriptions()
        #expect(initial.map(\.id) == ["UCSMOQeBJ2RAnuFungnQOxLg", "UCOKHwx1VCdgnxwbjyb9Iu1g"])
        #expect(initial.allSatisfy { if case .google = $0.source { true } else { false } })

        let subscriptionID = try await account.subscribe(channelID: "UCIXjev1_mJ1plJhF9lGarQg")
        #expect(try await account.subscriptions().count == 3)
        #expect(try await account.subscribe(channelID: "UCIXjev1_mJ1plJhF9lGarQg") == subscriptionID)
        #expect(try await account.subscriptions().count == 3)
        try await account.unsubscribe(subscriptionID: subscriptionID)
        #expect(try await account.subscriptions().map(\.id) == initial.map(\.id))

        #expect(try await account.rating(videoID: "dQw4w9WgXcQ") == .none)
        try await account.rate(videoID: "dQw4w9WgXcQ", rating: .like)
        #expect(try await account.rating(videoID: "dQw4w9WgXcQ") == .like)
        try await account.rate(videoID: "dQw4w9WgXcQ", rating: .none)
        #expect(try await account.rating(videoID: "dQw4w9WgXcQ") == .none)
    }

    @Test func accountServicePagesAndDurations() async throws {
        let account = MockAccountService(delay: .zero)
        #expect(try await account.myPlaylists().first?.id == "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B")

        let items = try await account.playlistItems(playlistID: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B", pageToken: nil)
        let itemsToken = try #require(items.continuation)
        let rest = try await account.playlistItems(playlistID: "PLsGl9GczcgBumq6fLmmR1ZYYn4EDkIg5B", pageToken: itemsToken)
        #expect(items.items.count + rest.items.count == 14 && rest.continuation == nil)

        let liked = try await account.likedVideos(pageToken: nil)
        let likedToken = try #require(liked.continuation)
        let likedRest = try await account.likedVideos(pageToken: likedToken)
        #expect(liked.items.count == 4 && likedRest.items.count == 3 && likedRest.continuation == nil)
        #expect((liked.items + likedRest.items).allSatisfy { !$0.isShort })

        let durations = try await account.durations(videoIDs: ["dQw4w9WgXcQ", "aqz-KE-bpKQ", "unknown"])
        #expect(durations == ["dQw4w9WgXcQ": 213, "aqz-KE-bpKQ": 635])
        try await account.addToPlaylist(videoID: "dQw4w9WgXcQ", playlistID: "PL1")
    }

    @Test func subscriptionFeedIsNewestFirstAndOnlyForTheGivenChannels() async throws {
        let feed = MockSubscriptionFeed(delay: .zero)
        #expect(await feed.cachedFeed().isEmpty)
        #expect(try await feed.feed(channels: [], forceRefresh: false).isEmpty)

        let blender = SubscribedChannel(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender")
        let videos = try await feed.feed(channels: [blender], forceRefresh: true)
        #expect(videos.first?.id == "mHrHLqQj7Ts")
        #expect(videos.allSatisfy { $0.channel?.id == blender.id })
        #expect(videos.compactMap(\.publishedAt) == videos.compactMap(\.publishedAt).sorted(by: >))
    }

    @Test func homeFeedAppliesTheContinueWatchingRules() async {
        let home = MockHomeFeed(delay: .zero)
        let videos = SampleData.videos
        let now = Date()
        let history = [
            HistoryEntry(video: videos[0], lastWatchedAt: now, progressSeconds: 600, durationSeconds: 15_550),   // in progress
            HistoryEntry(video: videos[1], lastWatchedAt: now, progressSeconds: 10, durationSeconds: 280),       // barely started
            HistoryEntry(video: videos[2], lastWatchedAt: now, progressSeconds: 630, durationSeconds: 635),      // finished
            HistoryEntry(video: videos[7], lastWatchedAt: now, progressSeconds: 100, durationSeconds: 200),      // a Short
        ]
        let feed = await home.homeFeed(history: history, subscriptionVideos: [])
        #expect(feed.continueWatching.map(\.id) == [videos[0].id])
        #expect(!feed.forYou.isEmpty)
        let watched = Set(history.map(\.id))
        #expect(feed.forYou.allSatisfy { !watched.contains($0.id) })
        #expect(Set(feed.forYou.map(\.id)).count == feed.forYou.count)
    }

    @Test func homeFeedPutsSubscriptionVideosFirstAndIsNeverEmpty() async {
        let home = MockHomeFeed(delay: .zero)
        let first = SampleData.videos[5]
        let feed = await home.homeFeed(history: [], subscriptionVideos: [first])
        #expect(feed.forYou.first?.id == first.id)
        #expect(feed.continueWatching.isEmpty)
        #expect(feed.forYou.count == SampleData.videos.count)
    }

    @Test func mocksHonourTheirDelay() async throws {
        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await MockStreamResolver(delay: .milliseconds(80)).streamInfo(videoID: "x")
        }
        #expect(elapsed >= .milliseconds(70))
    }

    @Test func aCancelledMockCallThrowsCancelled() async {
        let task = Task {
            try await MockYouTubeService(delay: .seconds(30)).search(query: "x", filter: SearchFilter())
        }
        task.cancel()
        await #expect(throws: NoSlopError.cancelled) { _ = try await task.value }
    }
}
