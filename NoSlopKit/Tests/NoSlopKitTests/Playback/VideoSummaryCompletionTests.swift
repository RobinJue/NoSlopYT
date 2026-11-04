import Foundation
import Testing
@testable import NoSlopKit

/// A link carries only a video id, so the player opens a bare summary and completes it as the stream and the watch page
/// answer. Completing fills what is empty and never replaces what is there.
@Suite struct VideoSummaryCompletionTests {
    private static let avatar = URL(string: "https://yt3.ggpht.com/avatar.jpg")!
    private static let otherAvatar = URL(string: "https://yt3.ggpht.com/other.jpg")!

    /// What the watch page says about the video.
    private func details(
        title: String = "Big Buck Bunny",
        channel: ChannelRef? = ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender", avatarURL: avatar, handle: "@blenderofficial"),
        viewCount: Int? = 23_500_582,
        viewCountText: String? = "23,500,582 views",
        publishedText: String? = "11 years ago"
    ) -> VideoSummary {
        VideoSummary(
            id: "aqz-KE-bpKQ",
            title: title,
            channel: channel,
            viewCount: viewCount,
            viewCountText: viewCountText,
            publishedText: publishedText
        )
    }

    private let bare = VideoSummary(id: "aqz-KE-bpKQ", title: "")

    @Test func aBareLinkTakesEverythingTheWatchPageKnows() {
        let completed = bare.filledIn(from: details())

        #expect(completed.title == "Big Buck Bunny")
        #expect(completed.channel == ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender", avatarURL: Self.avatar, handle: "@blenderofficial"))
        #expect(completed.viewCount == 23_500_582)
        #expect(completed.viewCountText == "23,500,582 views")
        #expect(completed.publishedText == "11 years ago")
        #expect(completed.id == "aqz-KE-bpKQ")
    }

    @Test func nothingThatIsAlreadyThereIsReplaced() {
        let known = VideoSummary(
            id: "aqz-KE-bpKQ",
            title: "Title from the stream",
            channel: ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender Foundation", avatarURL: Self.otherAvatar, handle: "@blender"),
            thumbnails: [Thumbnail(url: URL(string: "https://i.ytimg.com/vi/aqz-KE-bpKQ/hq.jpg")!, width: 480, height: 360)],
            durationSeconds: 635,
            viewCount: 5,
            viewCountText: "5 views",
            publishedText: "yesterday",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(known.filledIn(from: details()) == known)
    }

    @Test func aChannelFromTheStreamGetsItsAvatarAndHandleFromThePage() {
        // The stream knows the channel's id and name, but not its picture.
        var fromStream = bare
        fromStream.title = "Big Buck Bunny"
        fromStream.channel = ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender")

        let completed = fromStream.filledIn(from: details())

        #expect(completed.channel == ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender", avatarURL: Self.avatar, handle: "@blenderofficial"))
    }

    @Test func aChannelWithoutANameTakesTheOneOfThePage() {
        var unnamed = bare
        unnamed.channel = ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "")

        #expect(unnamed.filledIn(from: details()).channel?.name == "Blender")
    }

    @Test func aDifferentChannelKeepsItsOwnAvatarAndHandle() {
        // Should the two disagree about who uploaded the video, the page does not rewrite the channel.
        var other = bare
        other.channel = ChannelRef(id: "UCOKHwx1VCdgnxwbjyb9Iu1g", name: "Blender Guru")

        #expect(other.filledIn(from: details()).channel == ChannelRef(id: "UCOKHwx1VCdgnxwbjyb9Iu1g", name: "Blender Guru"))
    }

    @Test func aPageWithoutDetailsAddsNothing() {
        let empty = details(title: "", channel: nil, viewCount: nil, viewCountText: nil, publishedText: nil)
        #expect(bare.filledIn(from: empty) == bare)
    }

    @Test func blankTextsAreFilledLikeMissingOnes() {
        var blank = bare
        blank.viewCountText = ""
        blank.publishedText = "  "

        let completed = blank.filledIn(from: details())

        #expect(completed.viewCountText == "23,500,582 views")
        #expect(completed.publishedText == "11 years ago")
    }

    @Test func viewsAreTakenAsAPairOrNotAtAll() {
        // A copy that has the count but not the text keeps its count; the page's text must not be put next to it.
        var counted = bare
        counted.viewCount = 12

        let completed = counted.filledIn(from: details())

        #expect(completed.viewCount == 12)
        #expect(completed.viewCountText == nil)
    }

    @Test func aDifferentVideoIsNotTouched() {
        var other = details()
        other.id = "dQw4w9WgXcQ"
        #expect(bare.filledIn(from: other) == bare)
    }

    @Test func liveStateAndFlagsStayAsTheyWere() {
        // The stream decides live and upcoming (see `settingLiveState`); the page does not.
        var live = bare
        live.isLive = true
        live.isShort = true
        live.isMembersOnly = true
        var page = details()
        page.isLive = false

        let completed = live.filledIn(from: page)

        #expect(completed.isLive)
        #expect(completed.isShort)
        #expect(completed.isMembersOnly)
        #expect(!completed.isUpcoming)
    }
}
