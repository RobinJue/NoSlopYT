import Foundation
import Testing
@testable import NoSlopKit

/// Members-only videos in the lists that are made of lockups (a channel's tabs, "Up next", playlists): they must come
/// out flagged, because "Hide members-only videos" (on by default) filters on that flag and on nothing else.
///
/// `channel_members_only_videos.json` is a real answer, trimmed: the Videos tab of @LinusTechTips as `browse` returned
/// it on 2026-11-04 (hl=en, gl=US, params `EgZ2aWRlb3PyBgQKAjoA`), cut down to four items (two members-only ones, two
/// public ones) without the response context. The same request with hl=de gave the same chip with the text "Nur für
/// Kanalmitglieder": `{"badgeText":"Members only","badgeStyle":"BADGE_MEMBERS_ONLY","iconName":"SPONSORSHIP_STAR"}`
/// sits in a metadata row of its own, after the row with the age.
@Suite struct MembersOnlyVideosTests {
    private static let fixture = "channel_members_only_videos.json"
    private static let membersOnlyIDs = ["F3IO30jF_CA", "KxiUncxSnIo"]
    private static let publicIDs = ["vDmjw-c_R2k", "g9IOdTisQyM"]

    private func channelTabVideos() throws -> [VideoSummary] {
        ChannelParser.parseTab(try Fixture.json(Self.fixture)).items.compactMap(\.video)
    }

    @Test func aChannelTabFlagsItsMembersOnlyVideos() throws {
        let videos = try channelTabVideos()
        #expect(videos.map(\.id) == ["F3IO30jF_CA", "vDmjw-c_R2k", "g9IOdTisQyM", "KxiUncxSnIo"])
        #expect(videos.filter(\.isMembersOnly).map(\.id) == Self.membersOnlyIDs)
        #expect(videos.filter { !$0.isMembersOnly }.map(\.id) == Self.publicIDs)
    }

    @Test func theChipRowDoesNotChangeWhatElseIsReadFromTheLockup() throws {
        let videos = try channelTabVideos()
        let members = try #require(videos.first { $0.id == "F3IO30jF_CA" })
        #expect(members.title == "David Week - We Asked David 22 of Your Burning Questions! | Q&A")
        #expect(members.durationSeconds == 31 * 60)
        // A members-only video has no view count on a channel tab: the age is the only text row.
        #expect(members.publishedText == "1 day ago")
        #expect(members.viewCountText == nil)
        #expect(members.channel?.id == "UCXuqSBlHAE6Xw-yeJA0Tunw")
        #expect(!members.isLive && !members.isUpcoming && !members.isShort)

        let open = try #require(videos.first { $0.id == "vDmjw-c_R2k" })
        #expect(open.viewCountText == "3.5M views")
        #expect(open.viewCount == 3_500_000)
        #expect(open.publishedText == "1 day ago")
        #expect(open.durationSeconds == 30 * 60 + 50)
    }

    @Test func theDefaultFiltersDropThemAndTurningTheFilterOffKeepsThem() throws {
        let items = ChannelParser.parseTab(try Fixture.json(Self.fixture)).items

        let byDefault = ContentFilter(settings: AppSettings()).filter(items)
        #expect(byDefault.compactMap(\.video).map(\.id) == Self.publicIDs)

        var showAll = AppSettings()
        showAll.hideMembersOnly = false
        #expect(ContentFilter(settings: showAll).filter(items).compactMap(\.video).count == 4)
    }

    @Test func aMembersOnlyVideoInUpNextIsFlaggedAndFiltered() throws {
        // next_aqz.json is a real watch page. Its first status chip (the "Fundraiser" chip of the lockup of
        // xOXolSQcEb4, the 7th "Up next" item) is turned into the captured members-only chip.
        let chip = try JSON(data: Data(#"{"badgeText":"Members only","badgeStyle":"BADGE_MEMBERS_ONLY","iconName":"SPONSORSHIP_STAR"}"#.utf8))
        let original = try Fixture.json("next_aqz.json")
        let edited = BrowseJSONEdit.replacingFirstValue(forKey: "badgeViewModel", in: original) { _ in chip }

        let before = RelatedParser.parse(next: original).items
        let after = RelatedParser.parse(next: edited).items
        #expect(before.filter(\.isMembersOnly).isEmpty)
        #expect(after.count == before.count)
        #expect(after.filter(\.isMembersOnly).map(\.id) == ["xOXolSQcEb4"])
        // Nothing but that flag changed.
        #expect(after.filter { !$0.isMembersOnly } == before.filter { $0.id != "xOXolSQcEb4" })

        let flagged = try #require(after.first { $0.id == "xOXolSQcEb4" })
        #expect(!ContentFilter(settings: AppSettings()).allows(flagged))
        var showAll = AppSettings()
        showAll.hideMembersOnly = false
        #expect(ContentFilter(settings: showAll).allows(flagged))
    }

    @Test func theCapturedWatchPagesHaveNoMembersOnlyVideos() throws {
        // The other chips in the captures ("New", "CC", "Fundraiser") must not be taken for it.
        for name in ["next_aqz.json", "next_rickroll.json", "next_with_chapters.json"] {
            #expect(RelatedParser.parse(next: try Fixture.json(name)).items.allSatisfy { !$0.isMembersOnly }, "\(name)")
        }
        for name in ["channel_blender_home.json", "channel_blender_videos.json", "channel_blender_live.json"] {
            #expect(ChannelParser.parseTab(try Fixture.json(name)).items.compactMap(\.video).allSatisfy { !$0.isMembersOnly }, "\(name)")
        }
    }
}
