import Foundation
import Testing
@testable import NoSlopKit

private func makeVideo(
    _ id: String,
    title: String = "A perfectly fine video",
    channelID: String? = "UCfine",
    isLive: Bool = false,
    isUpcoming: Bool = false,
    isShort: Bool = false,
    isMembersOnly: Bool = false
) -> VideoSummary {
    VideoSummary(
        id: id,
        title: title,
        channel: channelID.map { ChannelRef(id: $0, name: "Channel \($0)") },
        isLive: isLive,
        isUpcoming: isUpcoming,
        isShort: isShort,
        isMembersOnly: isMembersOnly
    )
}

/// Settings with every filter switched off, so a test turns on exactly what it checks.
private func relaxed(_ change: (inout AppSettings) -> Void = { _ in }) -> AppSettings {
    var settings = AppSettings()
    settings.hideShorts = false
    settings.hideMembersOnly = false
    settings.hideLiveAndUpcoming = false
    settings.hideWatchedInSubscriptions = false
    change(&settings)
    return settings
}

@Suite struct ContentFilterTests {
    @Test func defaultSettingsHideShortsAndMembersOnlyContent() {
        let filter = ContentFilter(settings: AppSettings())
        #expect(!filter.allows(makeVideo("s", isShort: true)))
        #expect(!filter.allows(makeVideo("m", isMembersOnly: true)))
        #expect(filter.allows(makeVideo("l", isLive: true)))
        #expect(filter.allows(makeVideo("u", isUpcoming: true)))
        #expect(filter.allows(makeVideo("ok")))
    }

    @Test func hideShortsDropsShorts() {
        let on = ContentFilter(settings: relaxed { $0.hideShorts = true })
        let off = ContentFilter(settings: relaxed())
        #expect(!on.allows(makeVideo("s", isShort: true)))
        #expect(on.allows(makeVideo("v")))
        #expect(off.allows(makeVideo("s", isShort: true)))
    }

    @Test func hideMembersOnlyDropsMembersOnly() {
        let on = ContentFilter(settings: relaxed { $0.hideMembersOnly = true })
        let off = ContentFilter(settings: relaxed())
        #expect(!on.allows(makeVideo("m", isMembersOnly: true)))
        #expect(on.allows(makeVideo("v")))
        #expect(off.allows(makeVideo("m", isMembersOnly: true)))
    }

    @Test func hideLiveAndUpcomingDropsBoth() {
        let on = ContentFilter(settings: relaxed { $0.hideLiveAndUpcoming = true })
        let off = ContentFilter(settings: relaxed())
        #expect(!on.allows(makeVideo("l", isLive: true)))
        #expect(!on.allows(makeVideo("u", isUpcoming: true)))
        #expect(on.allows(makeVideo("v")))
        #expect(off.allows(makeVideo("l", isLive: true)))
        #expect(off.allows(makeVideo("u", isUpcoming: true)))
    }

    @Test func blockedChannelsDropByChannelID() {
        let filter = ContentFilter(settings: relaxed { $0.blockedChannels = [BlockedChannel(id: "UCbad", name: "Bad")] })
        #expect(!filter.allows(makeVideo("a", channelID: "UCbad")))
        #expect(filter.allows(makeVideo("b", channelID: "UCgood")))
        // Nothing is known about the channel, so there is nothing to block.
        #expect(filter.allows(makeVideo("c", channelID: nil)))
        // Only the id counts, not the (possibly renamed) channel name.
        #expect(filter.allows(VideoSummary(id: "d", title: "t", channel: ChannelRef(id: "UCother", name: "Bad"))))
    }

    @Test func blockedKeywordsMatchCaseInsensitively() {
        let filter = ContentFilter(settings: relaxed { $0.blockedKeywords = ["minecraft"] })
        #expect(!filter.allows(makeVideo("a", title: "MINECRAFT Speedrun")))
        #expect(!filter.allows(makeVideo("b", title: "my Minecraft world tour")))
        #expect(filter.allows(makeVideo("c", title: "Mine and craft")))
    }

    @Test func blockedKeywordsIgnoreDiacriticsInBothDirections() {
        let plainKeyword = ContentFilter(settings: relaxed { $0.blockedKeywords = ["cafe"] })
        let accentedKeyword = ContentFilter(settings: relaxed { $0.blockedKeywords = ["CAF\u{00C9}"] })
        #expect(!plainKeyword.allows(makeVideo("a", title: "Caf\u{00E9} tour")))
        #expect(!plainKeyword.allows(makeVideo("b", title: "Cafe\u{0301} tour")))
        #expect(!accentedKeyword.allows(makeVideo("c", title: "the best cafe")))
        #expect(!accentedKeyword.allows(makeVideo("d", title: "Caf\u{00E9}")))
    }

    @Test func blankKeywordsAreIgnoredAndOthersAreTrimmed() {
        let blanks = ContentFilter(settings: relaxed { $0.blockedKeywords = ["", "   ", "\n\t"] })
        #expect(blanks.allows(makeVideo("a", title: "anything at all")))
        #expect(blanks.allows(makeVideo("b", title: "")))

        let padded = ContentFilter(settings: relaxed { $0.blockedKeywords = ["", "  minecraft \n"] })
        #expect(!padded.allows(makeVideo("c", title: "Minecraft!")))
        #expect(padded.allows(makeVideo("d", title: "fine")))
    }

    @Test func anyOfSeveralKeywordsBlocks() {
        let filter = ContentFilter(settings: relaxed { $0.blockedKeywords = ["minecraft", "reaction"] })
        #expect(!filter.allows(makeVideo("a", title: "Reaction to everything")))
        #expect(!filter.allows(makeVideo("b", title: "Minecraft")))
        #expect(filter.allows(makeVideo("c", title: "Blender donut tutorial")))
    }

    @Test func hideWatchedOnlyAppliesInTheSubscriptionsContext() {
        let filter = ContentFilter(settings: relaxed { $0.hideWatchedInSubscriptions = true }, watchedIDs: ["seen"])
        #expect(!filter.allows(makeVideo("seen"), context: .subscriptions))
        #expect(filter.allows(makeVideo("seen"), context: .general))
        #expect(filter.allows(makeVideo("seen")))
        #expect(filter.allows(makeVideo("new"), context: .subscriptions))
    }

    @Test func watchedVideosStayWhenTheSettingIsOff() {
        let filter = ContentFilter(settings: relaxed(), watchedIDs: ["seen"])
        #expect(filter.allows(makeVideo("seen"), context: .subscriptions))
    }

    @Test func filteringAListKeepsTheOrderOfWhatRemains() {
        var settings = relaxed { $0.hideShorts = true; $0.blockedKeywords = ["spoiler"] }
        settings.hideWatchedInSubscriptions = true
        let filter = ContentFilter(settings: settings, watchedIDs: ["w"])
        let videos = [
            makeVideo("1"), makeVideo("2", isShort: true), makeVideo("3", title: "Spoiler alert"),
            makeVideo("w"), makeVideo("5"), makeVideo("6", channelID: nil),
        ]

        #expect(filter.filter(videos).map(\.id) == ["1", "w", "5", "6"])
        #expect(filter.filter(videos, context: .subscriptions).map(\.id) == ["1", "5", "6"])
        #expect(filter.filter([VideoSummary]()).isEmpty)
    }

    @Test func filteringSearchItemsDropsBlockedChannelsAndTheirPlaylists() {
        let filter = ContentFilter(settings: relaxed { $0.blockedChannels = [BlockedChannel(id: "UCbad", name: "Bad")] })
        let items: [SearchItem] = [
            .video(makeVideo("v1", channelID: "UCbad")),
            .channel(ChannelSummary(id: "UCbad", name: "Bad")),
            .channel(ChannelSummary(id: "UCgood", name: "Good")),
            .playlist(PlaylistSummary(id: "PL1", title: "By bad", channel: ChannelRef(id: "UCbad", name: "Bad"))),
            .playlist(PlaylistSummary(id: "PL2", title: "By good", channel: ChannelRef(id: "UCgood", name: "Good"))),
            .playlist(PlaylistSummary(id: "PL3", title: "Nobody knows")),
            .video(makeVideo("v2", channelID: "UCgood")),
        ]

        #expect(filter.filter(items).map(\.id) == ["channel:UCgood", "playlist:PL2", "playlist:PL3", "video:v2"])
    }

    @Test func filteringSearchItemsAppliesTheVideoRulesToVideos() {
        let filter = ContentFilter(settings: relaxed { $0.hideShorts = true; $0.blockedKeywords = ["minecraft"] })
        let items: [SearchItem] = [
            .video(makeVideo("short", isShort: true)),
            .video(makeVideo("mc", title: "Minecraft hardcore")),
            .video(makeVideo("ok")),
            .channel(ChannelSummary(id: "UCminecraft", name: "Minecraft fans")),
        ]

        #expect(filter.filter(items).map(\.id) == ["video:ok", "channel:UCminecraft"])
    }

    @Test func everythingPassesWithAllFiltersOffAndNothingBlocked() {
        let filter = ContentFilter(settings: relaxed())
        let videos = [makeVideo("a", isShort: true), makeVideo("b", isMembersOnly: true), makeVideo("c", isLive: true)]
        #expect(filter.filter(videos) == videos)
        #expect(filter.filter(videos.map(SearchItem.video)).count == 3)
    }
}
