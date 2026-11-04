import Foundation

/// What the Next button starts: the next queued video, and without a queue the first unwatched Up next video, as autoplay
/// would.
///
/// The button in the player controls and the Next of the lock screen ask the same question, so they cannot disagree about
/// whether there is a next video, or about which one it is. The order:
/// 1. a video that is queued,
/// 2. the next page of the list the queue came from, when nothing is queued but the list goes on,
/// 3. the first suggestion autoplay could start (`AutoplayPlanner.step`): not the video itself, not a watched one, not a
///    Short, a live stream or a premiere that has not started, nothing the viewer's filters hide,
/// 4. nothing: the button is disabled.
public enum NextVideo: Equatable, Sendable {
    /// Start the first queued video.
    case queued
    /// Wait for the next page of the list behind the queue, and start its first video (`QueueSource`).
    case nextPage
    /// Start a suggestion from Up next, with the others staying up next behind it. The queue is over, or there never was
    /// one.
    case suggested(AutoplayPlanner.Step)
    /// There is no next video.
    case nothing

    /// - Parameters:
    ///   - queued: how many videos are queued.
    ///   - listHasMore: the list the queue came from has pages that are not loaded yet.
    ///   - suggestion: what autoplay would start from the Up next list. Only worked out when nothing is queued: the
    ///     controls ask on every redraw.
    public static func choose(
        queued: Int,
        listHasMore: Bool,
        suggestion: @autoclosure () -> AutoplayPlanner.Step?
    ) -> NextVideo {
        if queued > 0 { return .queued }
        if listHasMore { return .nextPage }
        if let step = suggestion() { return .suggested(step) }
        return .nothing
    }

    /// There is something to start: the Next button is enabled.
    public var isAvailable: Bool {
        self != .nothing
    }
}
