import Foundation

/// What the player's error screen offers: whether it has a Retry button.
///
/// Retry asks YouTube again (fresh stream addresses, the same position). It is worth a button when the answer could be
/// different the next time: a dropped connection, a busy server, a bot check, an address that went stale. For a video
/// that YouTube will not hand to this app it only brings the same message back, and the screen then shows the reason and
/// the way out ("Open on YouTube") and nothing to press in vain.
public enum PlayerFailureAdvice {
    /// Whether the error screen of a video that could not be loaded with `error` offers Retry.
    ///
    /// - `NoSlopError.isWorthRetrying` says no for content YouTube calls gone (`unavailable`).
    /// - `unplayable` is how the `player` endpoint reports every verdict of YouTube's about a video: removed, private,
    ///   terminated channel, age-restricted, made for kids, blocked in the country. The README says it too: these videos
    ///   cannot be played through this kind of client, and asking again gets the same verdict, so there is no Retry. The
    ///   error alone cannot tell them from a live event that has not begun ("This live event will begin in 2 hours"),
    ///   which will play later, so a video that the app knows as live or upcoming keeps its Retry.
    /// - Anything else (no connection, a server error, a bot check, a response that could not be read) can pass.
    ///
    /// - Parameter video: the video that was being opened, as the list it came from described it; nil for a bare link.
    public static func isWorthRetrying(_ error: any Error, video: VideoSummary?) -> Bool {
        guard let error = error as? NoSlopError else { return true }
        guard error.isWorthRetrying else { return false }
        if case .unplayable = error {
            return video?.isLive == true || video?.isUpcoming == true
        }
        return true
    }

    /// Whether the error screen of a stream that failed while it played offers Retry. Every failure does but one: media
    /// that cannot be decoded on this device stays undecodable with fresh addresses (see `PlaybackRecovery`, which does
    /// not try it again either).
    public static func isWorthRetrying(_ failure: PlaybackFailure) -> Bool {
        failure != .decode
    }
}
