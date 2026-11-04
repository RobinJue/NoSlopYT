import Foundation

/// Where the mini player floats, so that it clears the tab bar.
public enum MiniPlayerPlacement {
    /// Whether the tab bar is at the top of the screen. That is so only for an iPad in a regular-width window.
    ///
    /// An iPhone has it at the bottom, also a Plus or Max held sideways (their width is regular too), and so has an
    /// iPad in a compact-width window: Slide Over, a narrow Split View, a narrowed window. So neither the device
    /// alone nor the size class alone is the answer.
    public static func tabBarIsAtTop(isPad: Bool, isRegularWidth: Bool) -> Bool {
        isPad && isRegularWidth
    }

    /// From the bottom safe area to the bottom of the mini player.
    ///
    /// With the tab bar at the top the bar floats just above the home indicator (8 pt). With it at the bottom, the
    /// iOS 26 floating tab bar rises about 48 pt above the safe area, and the mini player floats 10 pt above that.
    public static func bottomClearance(tabBarIsAtTop: Bool) -> Double {
        tabBarIsAtTop ? 8 : 58
    }
}
