import Foundation

/// What the viewer wants, playback running or paused, as far as the player's rate says.
///
/// The player controller keeps that wish itself: `play()` sets it and `pause()` clears it. But the pause and play
/// buttons of the Picture in Picture window and the remote of an AirPlay receiver reach `AVPlayer` directly, and
/// neither runs through the controller. Left alone, the wish would still say "playing" after the viewer paused in the
/// Picture in Picture window: the next quality change would start the video by itself, and so would the end of a phone
/// call. The rate tells what happened, and the reason `AVPlayer` gives for the change tells who did it.
public enum PlaybackIntent {
    /// Why the rate changed, as `AVPlayer.RateDidChangeReason` says.
    public enum RateChangeReason: Equatable, Sendable {
        /// Someone set the rate: the controller itself, or AVKit acting for the viewer (the Picture in Picture window,
        /// an AirPlay receiver's remote, the lock screen).
        case setRateCalled
        /// A change of the rate that did not work.
        case setRateFailed
        /// A call, Siri or another app took the audio.
        case audioSessionInterrupted
        /// The app went to the background with a video layer still on screen.
        case appBackgrounded
    }

    /// Whether the viewer wants playback after the rate of the player changed to `newRate`.
    ///
    /// Only a rate that someone *set* says something about the viewer's wish. What the system does on its own (an
    /// interruption, the background, the end of the video, a failure) says nothing, and `audioInterruptionBegan` and
    /// the background handling rely on the wish surviving it.
    ///
    /// - Parameters:
    ///   - newRate: the rate of the player now.
    ///   - reason: why it changed; nil when the player gave none.
    ///   - wasWanted: the wish before.
    ///   - isSettled: the player has an item that is ready and is neither recovering, nor ended, nor failed. Otherwise
    ///     the change is the controller taking an item down or putting one up (its own `pause()` of the old item
    ///     arrives like any other), and the wish stays.
    public static func wantsPlayback(
        afterRateChangeTo newRate: Float,
        reason: RateChangeReason?,
        wasWanted: Bool,
        isSettled: Bool
    ) -> Bool {
        guard isSettled, reason == .setRateCalled else { return wasWanted }
        return newRate != 0
    }
}
