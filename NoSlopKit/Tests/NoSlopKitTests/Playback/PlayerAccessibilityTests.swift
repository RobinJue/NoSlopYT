import Testing
@testable import NoSlopKit

@Suite struct PlayerAccessibilityTests {
    @Test func theControlsStayWhileAnAssistiveTechnologyIsRunning() {
        // Playing, faded out by the timer, nothing open: the state three seconds after the last touch.
        #expect(PlayerAccessibility.showsChrome(isVisible: false, isPlaybackRunning: true, isSettingsOpen: false, assistiveTechnologyOn: true))
        // Without one they are gone, as before.
        #expect(!PlayerAccessibility.showsChrome(isVisible: false, isPlaybackRunning: true, isSettingsOpen: false, assistiveTechnologyOn: false))
    }

    @Test func theRuleIsAnyOfTheFourReasons() {
        for isVisible in [false, true] {
            for isPlaybackRunning in [false, true] {
                for isSettingsOpen in [false, true] {
                    for assistive in [false, true] {
                        let shown = PlayerAccessibility.showsChrome(
                            isVisible: isVisible,
                            isPlaybackRunning: isPlaybackRunning,
                            isSettingsOpen: isSettingsOpen,
                            assistiveTechnologyOn: assistive
                        )
                        #expect(shown == (isVisible || !isPlaybackRunning || isSettingsOpen || assistive))
                    }
                }
            }
        }
    }

    @Test func theSkipNoticeStaysLongerForAssistiveTechnology() {
        #expect(PlayerAccessibility.skipNoticeDuration(assistiveTechnologyOn: false) == .seconds(4))
        #expect(PlayerAccessibility.skipNoticeDuration(assistiveTechnologyOn: true) == .seconds(10))
    }
}
