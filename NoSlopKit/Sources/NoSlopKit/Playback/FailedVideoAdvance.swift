import Foundation

/// Whether the player goes on to the next video by itself when a video it started cannot be played.
///
/// A queue (a whole playlist, the liked videos) or autoplay must not end at one private, age-restricted or blocked
/// entry. But only a failure that asking again cannot change is skipped; a dropped connection keeps its Retry. Only a
/// video that the queue, autoplay or Next started is skipped, never one the viewer opened on purpose, and only a few
/// in a row: a verdict that holds for a whole list must not send one request per entry.
public enum FailedVideoAdvance {
    public enum Action: Equatable, Sendable {
        /// Show the failure for `delay`, then start the next video.
        case skipToNext
        /// Leave the error screen as it is.
        case stay
    }

    /// How many videos in a row are skipped; the counter resets when a video plays or the viewer opens one.
    public static let maxSkipsInARow = 3

    /// How long the failure is shown (error screen or mini player) before the next video starts.
    public static let delay: Duration = .seconds(2)

    /// - Parameters:
    ///   - isWorthRetrying: asking again could end differently (network, bot check, a live event not begun).
    ///   - reachedByAdvance: the queue, autoplay or Next started the video, not the viewer.
    ///   - hasNext: a queued video or a suggestion could follow.
    ///   - skippedInARow: videos skipped since the last one that played or was opened by the viewer.
    public static func action(
        isWorthRetrying: Bool, reachedByAdvance: Bool, hasNext: Bool, skippedInARow: Int
    ) -> Action {
        guard !isWorthRetrying, reachedByAdvance, hasNext, skippedInARow < maxSkipsInARow else { return .stay }
        return .skipToNext
    }
}
