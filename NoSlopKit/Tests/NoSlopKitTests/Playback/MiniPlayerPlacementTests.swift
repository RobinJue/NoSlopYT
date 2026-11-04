import Testing
@testable import NoSlopKit

@Suite struct MiniPlayerPlacementTests {
    @Test func theTabBarIsAtTheTopOnlyOnAnIPadInARegularWidthWindow() {
        // iPad, full screen or a wide window.
        #expect(MiniPlayerPlacement.tabBarIsAtTop(isPad: true, isRegularWidth: true))
        // iPad in Slide Over, a narrow Split View or a narrowed window: the tab bar is at the bottom, as on an iPhone.
        #expect(!MiniPlayerPlacement.tabBarIsAtTop(isPad: true, isRegularWidth: false))
    }

    @Test func anIPhoneAlwaysHasItAtTheBottom() {
        // Upright.
        #expect(!MiniPlayerPlacement.tabBarIsAtTop(isPad: false, isRegularWidth: false))
        // A Plus or Max held sideways is regular width too, and still has the tab bar at the bottom.
        #expect(!MiniPlayerPlacement.tabBarIsAtTop(isPad: false, isRegularWidth: true))
    }

    @Test func theMiniPlayerClearsTheTabBarOnlyWhereItIsAtTheBottom() {
        #expect(MiniPlayerPlacement.bottomClearance(tabBarIsAtTop: true) == 8)
        #expect(MiniPlayerPlacement.bottomClearance(tabBarIsAtTop: false) == 58)
    }
}
