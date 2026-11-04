import Foundation

/// The on-device "For you" feed.
public struct HomeFeed: Sendable {
    public var continueWatching: [HistoryEntry]
    public var forYou: [VideoSummary]
    /// YouTube could not be asked for related videos: the history had videos to base them on, and not one of their watch
    /// pages answered (no connection, a timeout, a block). "For you" is then only what could be built without them, so an
    /// empty one says "could not load", not "that is everything".
    public var relatedUnavailable: Bool

    public init(continueWatching: [HistoryEntry] = [], forYou: [VideoSummary] = [], relatedUnavailable: Bool = false) {
        self.continueWatching = continueWatching
        self.forYou = forYou
        self.relatedUnavailable = relatedUnavailable
    }

    public static let empty = HomeFeed()

    /// "Continue watching" for `history` (most recent first): the entries that are at least 30 s in, not finished and not
    /// Shorts, the ten most recent, in the order of the history. It needs no network, so a screen can show it before
    /// the rest of the feed has been built.
    public static func continueWatching(in history: [HistoryEntry]) -> [HistoryEntry] {
        Array(history.lazy.filter(isWorthResuming).prefix(continueWatchingLimit))
    }

    private static let continueWatchingLimit = 10
    private static let minimumContinueWatchingSeconds = 30.0

    private static func isWorthResuming(_ entry: HistoryEntry) -> Bool {
        entry.progressSeconds >= minimumContinueWatchingSeconds && !entry.isFinished && !entry.video.isShort
    }
}
