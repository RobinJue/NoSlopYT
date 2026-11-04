import Foundation

/// What the player's error screen offers: whether it has a Retry button.
///
/// Retry asks YouTube again (fresh stream addresses, the same position). It is worth a button when the answer could be
/// different the next time: a dropped connection, a busy server, a bot check, an address that went stale, a live event
/// that begins in the meantime. For a video that YouTube will not hand to this app it only brings the same message back,
/// and the screen then shows the reason and the way out ("Open on YouTube") and nothing to press in vain.
public enum PlayerFailureAdvice {
    /// Whether the error screen of a video that could not be loaded with `error` offers Retry.
    ///
    /// - `NoSlopError.isWorthRetrying` says no for content YouTube calls gone (`unavailable`).
    /// - `unplayable` is how the `player` endpoint reports a verdict of YouTube's about a video: removed, private,
    ///   terminated channel, age-restricted, made for kids, blocked in the country. The README says it too: these videos
    ///   cannot be played through this kind of client, and asking again gets the same verdict, so there is no Retry.
    /// - A live event or a premiere that has not begun, and an answer that came without a stream, are `notPlayableYet`,
    ///   not `unplayable`: the video will play later, or the next answer may have a stream. The error alone decides, not the
    ///   copy of the video that was opened: a pasted link, a share link and `noslop://watch` open a video the app knows
    ///   nothing about (not even that it is live), and the copies that History, Watch Later and playlists keep have no
    ///   live or upcoming flags either.
    /// - Anything else (no connection, a server error, a bot check, a response that could not be read) can pass.
    public static func isWorthRetrying(_ error: any Error) -> Bool {
        guard let error = error as? NoSlopError else { return true }
        if case .unplayable = error { return false }
        return error.isWorthRetrying
    }

    /// Whether the error screen of a video that failed while it played offers Retry. Every failure does but one: media
    /// that cannot be decoded on this device stays undecodable with fresh addresses (see `PlaybackRecovery`, which does
    /// not try it again either).
    ///
    /// Except for a download. Retry of a video that plays from a download does not ask for fresh addresses: it streams
    /// the video instead (the player's `forceStreaming`), so it is no repeat of what failed. A file that is damaged or
    /// in a format this device cannot play would otherwise leave no way to watch the video in the app, until the
    /// download is deleted.
    ///
    /// - Parameter isPlayingOffline: the video was playing from a download.
    public static func isWorthRetrying(_ failure: PlaybackFailure, isPlayingOffline: Bool) -> Bool {
        failure != .decode || isPlayingOffline
    }
}
