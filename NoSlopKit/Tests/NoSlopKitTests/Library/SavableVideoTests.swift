import Foundation
import Testing
@testable import NoSlopKit

/// A video opened from a link starts as a bare summary (an id and no title) until the stream or the watch page answers,
/// and the player completes its own copy then. What a sheet puts into a playlist or the download queue is that copy, and
/// nothing is put there while no title is known: a row with a thumbnail and nothing else would stay blank for good.
@Suite struct SavableVideoTests {
    private static let id = "aqz-KE-bpKQ"
    private static let channel = ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender")

    private let bare = VideoSummary(id: SavableVideoTests.id, title: "")

    /// The player's copy of the same video once the stream has answered.
    private let learned = VideoSummary(
        id: SavableVideoTests.id,
        title: "Big Buck Bunny",
        channel: SavableVideoTests.channel,
        durationSeconds: 635
    )

    @Test func aVideoWithATitleIsSavedAsItIs() {
        let listed = VideoSummary(id: Self.id, title: "From a list", channel: Self.channel, viewCountText: "5 views")

        #expect(listed.savableCopy(completedBy: nil) == listed)
        #expect(listed.savableCopy(completedBy: bare) == listed)
    }

    @Test func aBareVideoTakesTheTitleAndChannelTheStreamBrought() {
        let saved = bare.savableCopy(completedBy: learned)

        #expect(saved?.id == Self.id)
        #expect(saved?.title == "Big Buck Bunny")
        #expect(saved?.channel == Self.channel)
        #expect(saved?.durationSeconds == 635)
    }

    @Test func nothingIsSavedWhileNoTitleIsKnown() {
        #expect(bare.savableCopy(completedBy: nil) == nil)
        #expect(bare.savableCopy(completedBy: bare) == nil)
        // The player knows the channel but not the title yet.
        var channelOnly = bare
        channelOnly.channel = Self.channel
        #expect(bare.savableCopy(completedBy: channelOnly) == nil)
    }

    @Test func blanksAreNoTitle() {
        let blank = VideoSummary(id: Self.id, title: " \n\t ")

        #expect(blank.savableCopy(completedBy: nil) == nil)
        #expect(blank.savableCopy(completedBy: VideoSummary(id: Self.id, title: "  ")) == nil)
        #expect(blank.savableCopy(completedBy: learned)?.title == "Big Buck Bunny")
    }

    @Test func theCopyOfAnotherVideoIsNotUsed() {
        // The player has moved on (autoplay) while the sheet was still open.
        let other = VideoSummary(id: "jNQXAC9IVRw", title: "Me at the zoo", channel: ChannelRef(id: "UC4QobU6STFB0P71PMvOGN5A", name: "jawed"))

        #expect(bare.savableCopy(completedBy: other) == nil)
        let listed = VideoSummary(id: Self.id, title: "From a list")
        #expect(listed.savableCopy(completedBy: other) == listed)
    }

    @Test func whatTheVideoAlreadyHasIsNotReplacedByThePlayersCopy() {
        let listed = VideoSummary(id: Self.id, title: "Title from the list")
        var player = learned
        player.title = "Title from the stream"

        let saved = listed.savableCopy(completedBy: player)

        #expect(saved?.title == "Title from the list")
        // What it lacks is filled in.
        #expect(saved?.channel == Self.channel)
        #expect(saved?.durationSeconds == 635)
    }
}
