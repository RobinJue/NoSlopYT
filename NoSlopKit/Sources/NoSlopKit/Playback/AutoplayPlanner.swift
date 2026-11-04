import Foundation

/// Chooses the video autoplay starts when the current one ends, and what stays up next behind it.
///
/// The up-next list comes from the watch page, which only hands it over while it is on screen. When autoplay moves on
/// to the next video with the player minimized, nobody replaces the list, so the player keeps what remains of it
/// (`Step.remaining`) and the next hop can use it. The watch page replaces the list as soon as it loads the new
/// video's related videos.
public enum AutoplayPlanner {
    /// A video counts as watched once this many seconds of it have played.
    public static let watchedAfter: Double = 10

    public struct Step: Equatable, Sendable {
        /// The video to start.
        public var next: VideoSummary
        /// The suggestions that stay up next once `next` has started: the ones autoplay could still choose, in order.
        public var remaining: [VideoSummary]

        public init(next: VideoSummary, remaining: [VideoSummary]) {
            self.next = next
            self.remaining = remaining
        }
    }

    /// The first suggestion autoplay can start, with the ones that stay up next behind it.
    ///
    /// A suggestion is skipped when it is the video that just ended, when the viewer has watched it (at least
    /// `watchedAfter` seconds), when it is a Short, a live stream or a premiere that has not started, and when the
    /// viewer's filters do not allow it (a channel blocked since the list was published, members-only videos, blocked
    /// keywords). None of those stays in `remaining`: the video just started and anything watched are gone, and so is
    /// what autoplay would pass over anyway.
    ///
    /// - Parameters:
    ///   - currentVideoID: the video that just ended.
    ///   - upNext: the suggestions, in order.
    ///   - progress: the seconds played of a video; nil when the viewer never watched it.
    ///   - allows: whether the viewer's filters let a suggestion through, as of now. The list may be older than the
    ///     last change of the filters (the player was minimized, or the list was carried over from an earlier video),
    ///     so the player asks with the settings it has when autoplay decides. Allows everything by default.
    /// - Returns: nil when no suggestion can be started.
    public static func step(
        after currentVideoID: String?,
        upNext: [VideoSummary],
        progress: (String) -> Double?,
        allows: (VideoSummary) -> Bool = { _ in true }
    ) -> Step? {
        let candidates = upNext.filter { video in
            video.id != currentVideoID
                && !video.isShort && !video.isLive && !video.isUpcoming
                && allows(video)
                && (progress(video.id) ?? 0) < watchedAfter
        }
        guard let next = candidates.first else { return nil }
        return Step(next: next, remaining: candidates.filter { $0.id != next.id })
    }
}
