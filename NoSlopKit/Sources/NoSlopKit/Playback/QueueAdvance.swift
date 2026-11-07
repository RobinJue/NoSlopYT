import Foundation

/// What the player does when the page of videos it was waiting for has come in (or has failed to).
///
/// The queue normally has the next video ready. Two things can find it empty while the list behind it goes on: the
/// video ends before the page arrived (a run of short videos, a slow connection), and the viewer presses Next on the
/// lock screen in that moment. Either way the player asks the source for the page and decides what to do with the answer.
public enum QueueAdvance {
    /// Why the player is waiting for a page.
    public enum Request: Equatable, Sendable {
        /// The video ended with nothing queued: the video that follows is in the page.
        case whenEnded
        /// The viewer asked for the next video while nothing was queued.
        case now
    }

    public enum Action: Equatable, Sendable {
        /// Start the first queued video.
        case startNext
        /// The queue is over: it is autoplay's turn, as at the end of any queue.
        case autoplay
        /// The list is over and the viewer asked for the next video: it is the suggestion's turn, whatever the autoplay
        /// setting says (Next works with autoplay off).
        case suggestion
        /// Leave the player as it is.
        case nothing
    }

    /// - Parameters:
    ///   - request: why the player waited; nil when nobody did.
    ///   - queued: how many videos are queued now, after the page.
    ///   - isEnded: the current video has ended and nothing has started it again since.
    ///   - listIsOver: the source has no more pages. A failed page leaves this false, so a blip never abandons the list.
    public static func action(for request: Request?, queued: Int, isEnded: Bool, listIsOver: Bool = false) -> Action {
        guard let request else { return .nothing }
        if queued > 0 {
            switch request {
            case .now:
                return .startNext
            case .whenEnded:
                // The viewer replayed the video, or sought, while the page was on its way: it is not over any more.
                return isEnded ? .startNext : .nothing
            }
        }
        if request == .now && listIsOver { return .suggestion }
        // Nothing came: the list is over, or could not be reached. A video that still plays plays on.
        return isEnded ? .autoplay : .nothing
    }
}
