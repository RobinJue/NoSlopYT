import Foundation

/// Where a video that a link opens "in a playlist" (`watch?v=…&list=…`) stands in that playlist, and which videos
/// follow it: the same queue "Play all" from that row would make.
public struct PlaylistQueueStart: Equatable, Sendable {
    /// 1-based position of the video in the queue (the videos before it that the filters let through, plus one).
    public let position: Int
    /// The videos that play after it.
    public let queued: [VideoSummary]
    /// The video was found in the playlist. When it was not, the queue is the playlist from its start.
    public let videoWasFound: Bool

    /// - Parameters:
    ///   - videoID: the video the link opened.
    ///   - items: the playlist as loaded so far, in order and before the viewer's filters.
    ///   - filter: the viewer's filters, applied to the videos before and after; the video itself always plays.
    public static func make(
        videoID: String,
        in items: [VideoSummary],
        filter: ([VideoSummary]) -> [VideoSummary] = { $0 }
    ) -> PlaylistQueueStart {
        guard let index = items.firstIndex(where: { $0.id == videoID }) else {
            return PlaylistQueueStart(position: 1, queued: filter(items).filter { $0.id != videoID }, videoWasFound: false)
        }
        let before = filter(Array(items[..<index])).filter { $0.id != videoID }
        let after = filter(Array(items[(index + 1)...])).filter { $0.id != videoID }
        return PlaylistQueueStart(position: before.count + 1, queued: after, videoWasFound: true)
    }
}
