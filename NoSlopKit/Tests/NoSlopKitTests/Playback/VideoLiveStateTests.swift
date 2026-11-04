import Testing
@testable import NoSlopKit

@Suite struct VideoLiveStateTests {
    private func saved(isLive: Bool, isUpcoming: Bool = false) -> VideoSummary {
        VideoSummary(
            id: "aqz-KE-bpKQ",
            title: "A stream that ended",
            channel: ChannelRef(id: "UCSMOQeBJ2RAnuFungnQOxLg", name: "Blender"),
            durationSeconds: 213,
            viewCount: 1_234,
            publishedText: "2 days ago",
            isLive: isLive,
            isUpcoming: isUpcoming,
            isMembersOnly: true
        )
    }

    @Test func aBroadcastThatHasEndedIsNoLongerLive() {
        let settled = saved(isLive: true).settingLiveState(to: false)
        #expect(settled.isLive == false)
        #expect(settled.isUpcoming == false)
    }

    @Test func aPremiereThatHasStartedIsNoLongerUpcoming() {
        let settled = saved(isLive: false, isUpcoming: true).settingLiveState(to: false)
        #expect(settled.isLive == false)
        #expect(settled.isUpcoming == false)
    }

    @Test func aStaleCopyThatSaysBothIsSettledToWhatTheStreamSays() {
        let ended = saved(isLive: true, isUpcoming: true)
        #expect(ended.settingLiveState(to: false).isLive == false)
        #expect(ended.settingLiveState(to: false).isUpcoming == false)
        #expect(ended.settingLiveState(to: true).isLive == true)
        #expect(ended.settingLiveState(to: true).isUpcoming == false)
    }

    @Test func aStreamThatIsLiveMakesTheVideoLive() {
        // A live stream opened from a card that did not know.
        let settled = saved(isLive: false).settingLiveState(to: true)
        #expect(settled.isLive == true)
        #expect(settled.isUpcoming == false)
    }

    @Test func aCopyThatAlreadyAgreesIsLeftAsItIs() {
        let ordinary = saved(isLive: false)
        #expect(ordinary.settingLiveState(to: false) == ordinary)
        let live = saved(isLive: true)
        #expect(live.settingLiveState(to: true) == live)
    }

    @Test func nothingElseAboutTheVideoChanges() {
        let original = saved(isLive: true, isUpcoming: true)
        var settled = original.settingLiveState(to: false)
        settled.isLive = original.isLive
        settled.isUpcoming = original.isUpcoming
        #expect(settled == original)
    }
}
