import Foundation

/// The on-device "For you" feed.
public struct HomeFeed: Sendable {
    public var continueWatching: [HistoryEntry]
    public var forYou: [VideoSummary]

    public init(continueWatching: [HistoryEntry] = [], forYou: [VideoSummary] = []) {
        self.continueWatching = continueWatching
        self.forYou = forYou
    }

    public static let empty = HomeFeed()
}
