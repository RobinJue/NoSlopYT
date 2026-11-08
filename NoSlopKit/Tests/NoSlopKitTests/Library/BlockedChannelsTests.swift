import Foundation
import Testing
@testable import NoSlopKit

// "Don't show this channel" and its undo, "Show this channel again", in the video menus.
@Suite struct BlockedChannelsTests {
    @Test func blockingAddsTheChannelOnceAndNothingIsBlockedByDefault() {
        var settings = AppSettings()
        #expect(!settings.isBlocked(channelID: "UC1"))

        let first = settings.blockChannel(id: "UC1", name: "One")
        #expect(first)
        #expect(settings.blockedChannels == [BlockedChannel(id: "UC1", name: "One")])
        #expect(settings.isBlocked(channelID: "UC1"))
        #expect(!settings.isBlocked(channelID: "UC2"))

        // A second tap changes nothing, and says so.
        let again = settings.blockChannel(id: "UC1", name: "One")
        let renamed = settings.blockChannel(id: "UC1", name: "Renamed")
        #expect(!again)
        #expect(!renamed)
        #expect(settings.blockedChannels == [BlockedChannel(id: "UC1", name: "One")])
    }

    @Test func aChannelWithoutAnIDCannotBeBlocked() {
        var settings = AppSettings()
        let blocked = settings.blockChannel(id: "", name: "Nameless")
        #expect(!blocked)
        #expect(settings.blockedChannels.isEmpty)
        #expect(!settings.isBlocked(channelID: ""))
    }

    @Test func unblockingRemovesThatChannelByIDOnly() {
        var settings = AppSettings()
        settings.blockChannel(id: "UC1", name: "One")
        settings.blockChannel(id: "UC2", name: "Two")
        settings.blockChannel(id: "UC3", name: "Three")

        let removed = settings.unblockChannel(id: "UC2")
        #expect(removed)
        #expect(settings.blockedChannels.map(\.id) == ["UC1", "UC3"])
        #expect(!settings.isBlocked(channelID: "UC2"))
        #expect(settings.isBlocked(channelID: "UC1") && settings.isBlocked(channelID: "UC3"))

        // Not blocked (any more): nothing to undo.
        let twice = settings.unblockChannel(id: "UC2")
        let unknown = settings.unblockChannel(id: "UC9")
        let empty = settings.unblockChannel(id: "")
        #expect(!twice && !unknown && !empty)
        #expect(settings.blockedChannels.map(\.id) == ["UC1", "UC3"])
    }

    @Test func aChannelCanBeBlockedAgainAfterItWasShownAgain() {
        var settings = AppSettings()
        settings.blockChannel(id: "UC1", name: "One")
        settings.unblockChannel(id: "UC1")
        #expect(settings.blockedChannels.isEmpty)
        let again = settings.blockChannel(id: "UC1", name: "One")
        #expect(again)
        #expect(settings.isBlocked(channelID: "UC1"))
    }

    @Test func aBlockedChannelIsHiddenByTheFilterAndShownAgainAfterTheUndo() {
        var settings = AppSettings()
        let video = VideoSummary(id: "v", title: "t", channel: ChannelRef(id: "UC1", name: "One"))
        #expect(ContentFilter(settings: settings).allows(video))

        settings.blockChannel(id: "UC1", name: "One")
        #expect(!ContentFilter(settings: settings).allows(video))

        settings.unblockChannel(id: "UC1")
        #expect(ContentFilter(settings: settings).allows(video))
    }

    @Test func theListSurvivesTheSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.blockChannel(id: "UC1", name: "One")
        settings.blockChannel(id: "UC2", name: "Two")
        settings.unblockChannel(id: "UC1")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded.blockedChannels == [BlockedChannel(id: "UC2", name: "Two")])
        #expect(decoded.isBlocked(channelID: "UC2") && !decoded.isBlocked(channelID: "UC1"))
    }

    // A Home tile has no id and is hidden by the name it shows; the block resolved through the watch page must still match it.
    @Test func resolvingATileKeepsTheTileNameSoTheBlockMatchesTheTile() {
        let tile = ChannelRef(id: "", name: "Fireship Official")
        let details = ChannelRef(id: "UC1", name: "Fireship", handle: "@fireship")
        let resolved = ChannelRef.resolvedForBlocking(details: details, tile: tile)
        #expect(resolved.id == "UC1")
        #expect(resolved.name == "Fireship Official")
        #expect(resolved.handle == "@fireship")

        var settings = AppSettings()
        let added = settings.blockChannel(id: resolved.id, name: resolved.name, handle: resolved.handle)
        #expect(added)
        #expect(settings.blockedChannel(matching: tile)?.id == "UC1")
        #expect(!ContentFilter(settings: settings).allows(VideoSummary(id: "v", title: "t", channel: tile)))
    }

    @Test func resolvingKeepsTheDetailsNameWhenThereIsNoHandleAndTheNamesDiffer() {
        let tile = ChannelRef(id: "", name: "Some  Channel")
        let details = ChannelRef(id: "UC2", name: "Some Channel VEVO")
        let resolved = ChannelRef.resolvedForBlocking(details: details, tile: tile)
        #expect(resolved.name == "Some  Channel")
        #expect(resolved.handle == "Some Channel VEVO")

        let same = ChannelRef.resolvedForBlocking(details: ChannelRef(id: "UC3", name: "Same"), tile: ChannelRef(id: "", name: "same"))
        #expect(same.handle == nil)

        let blankTile = ChannelRef.resolvedForBlocking(details: details, tile: ChannelRef(id: "", name: ""))
        #expect(blankTile.name == "Some Channel VEVO")
        #expect(blankTile.handle == nil)
    }
}
