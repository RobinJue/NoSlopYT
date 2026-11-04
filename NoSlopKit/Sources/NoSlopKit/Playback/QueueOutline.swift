import Foundation

/// How the watch page describes the queue that plays: where it came from, where in it the video is, and the next few
/// videos of it.
///
/// "Play all" and a tap on a row of a list queue the videos behind that row, and a long list (a playlist, the liked
/// videos) arrives in pages: the queue has the loaded ones and the player asks for the next page when it runs low
/// (`QueueSource`). So the total is only known once the last page is in. Until then the position reads "3 of 100+".
public struct QueueOutline: Equatable, Sendable {
    /// How many of the queued videos the watch page lists; the others follow in order.
    public static let upcomingLimit = 3

    /// The list the queue came from ("Liked videos", the title of a playlist); nil for a queue that has no name.
    public let name: String?
    /// 1 for the video the list was opened with, and one more for every video the queue moves on to.
    public let position: Int
    /// The videos queued behind the one that plays, as far as they are loaded.
    public let queuedCount: Int
    /// The list goes on behind what is loaded: more pages may come, so the total is not final.
    public let hasMore: Bool
    /// The next videos of the queue, at most `upcomingLimit`.
    public let upcoming: [VideoSummary]

    /// - Parameters:
    ///   - name: where the queue came from; blank means no name.
    ///   - position: 1-based position of the video that plays.
    ///   - queued: the videos behind it.
    ///   - hasMore: the list the queue came from has pages that are not loaded yet.
    /// - Returns: nil when no queue plays (`position` is below 1).
    public init?(name: String?, position: Int, queued: [VideoSummary], hasMore: Bool) {
        guard position >= 1 else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        self.position = position
        self.queuedCount = queued.count
        self.hasMore = hasMore
        self.upcoming = Array(queued.prefix(Self.upcomingLimit))
    }

    /// The videos of the queue that are loaded: those played so far, the one that plays and those queued behind it.
    public var total: Int {
        position + queuedCount
    }

    /// "Playing from Liked videos"; "Playing from your queue" when the queue has no name.
    public var title: String {
        guard let name else { return "Playing from your queue" }
        return "Playing from \(name)"
    }

    /// "3 of 14", or "3 of 100+" while more pages may come.
    public var positionText: String {
        "\(position) of \(total)\(hasMore ? "+" : "")"
    }

    /// `positionText` as it is read out: "Video 3 of 14", "Video 3 of at least 100".
    public var spokenPositionText: String {
        hasMore ? "Video \(position) of at least \(total)" : "Video \(position) of \(total)"
    }
}
