import Foundation

/// What the player does differently while VoiceOver or Switch Control is running.
public enum PlayerAccessibility {
    /// Whether the player's controls are on screen.
    ///
    /// They fade out three seconds after the last touch while the video plays. Swiping from one control to the next
    /// is not a touch and takes longer than that, so while an assistive technology is running the controls stay: a
    /// button that disappears in the middle of the swipe cannot be reached at all.
    ///
    /// Otherwise they show when the viewer asked for them (`isVisible`), whenever the video is not running (paused,
    /// ended, loading, failed), and while the settings popover is open.
    public static func showsChrome(
        isVisible: Bool,
        isPlaybackRunning: Bool,
        isSettingsOpen: Bool,
        assistiveTechnologyOn: Bool
    ) -> Bool {
        isVisible || !isPlaybackRunning || isSettingsOpen || assistiveTechnologyOn
    }

    /// How long "Skipped sponsor · Undo" stays on screen after SponsorBlock jumped over a segment. Hearing the
    /// announcement, finding the video and choosing "Undo skip" takes a VoiceOver or Switch Control user longer than
    /// the four seconds that are enough to tap a button.
    public static func skipNoticeDuration(assistiveTechnologyOn: Bool) -> Duration {
        assistiveTechnologyOn ? .seconds(10) : .seconds(4)
    }
}
