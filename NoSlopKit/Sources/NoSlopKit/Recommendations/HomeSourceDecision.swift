import Foundation

/// Decides whether YouTube's Home is good enough to show, or the on-device mix takes over (port of the probe's
/// `home_try_passes`): page 1 must be logged in and the first three pages must hold at least eight unique videos that
/// pass the filter and are not in `excluded` (Continue watching and finished videos).
public enum HomeSourceDecision {
    public static let minimumVisible = 8
    public static let maximumPages = 3

    public struct Result: Sendable {
        public let useYouTube: Bool
        /// The unique videos that pass the filter, in page order; empty when YouTube is not used.
        public let videos: [VideoSummary]
        /// The token for the next page after the last page considered; nil when YouTube is not used.
        public let continuation: String?

        public init(useYouTube: Bool, videos: [VideoSummary], continuation: String?) {
            self.useYouTube = useYouTube
            self.videos = videos
            self.continuation = continuation
        }
    }

    public static func decide(pages: [TVHomePage], filter: (VideoSummary) -> Bool, excluded: Set<String>) -> Result {
        let considered = Array(pages.prefix(maximumPages))
        guard considered.first?.loggedIn == true else {
            return Result(useYouTube: false, videos: [], continuation: nil)
        }
        var seen = Set<String>()
        var videos: [VideoSummary] = []
        for page in considered {
            for video in page.videos where !excluded.contains(video.id) && filter(video) && seen.insert(video.id).inserted {
                videos.append(video)
            }
        }
        guard videos.count >= minimumVisible else {
            return Result(useYouTube: false, videos: [], continuation: nil)
        }
        return Result(useYouTube: true, videos: videos, continuation: considered.last?.continuation)
    }
}
