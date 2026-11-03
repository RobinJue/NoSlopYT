import Foundation

/// `YouTubeService` backed by InnerTube.
///
/// STUB (Task 1A). Task 2 owns this file: every member throws `NoSlopError.notImplemented`.
public struct InnerTubeYouTubeService: YouTubeService {
    public init(client: InnerTubeClient, http: any HTTPClient) {}

    public func search(query: String, filter: SearchFilter) async throws -> Page<SearchItem> {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.search")
    }

    public func searchMore(continuation: String) async throws -> Page<SearchItem> {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.searchMore")
    }

    public func suggestions(for query: String) async throws -> [String] {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.suggestions")
    }

    public func videoDetails(id: String) async throws -> VideoDetails {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.videoDetails")
    }

    public func moreRelated(continuation: String) async throws -> Page<VideoSummary> {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.moreRelated")
    }

    public func comments(continuation: String) async throws -> CommentsPage {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.comments")
    }

    public func channel(id: String) async throws -> ChannelPage {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.channel")
    }

    public func channelTab(channelID: String, tab: ChannelTabKind) async throws -> Page<SearchItem> {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.channelTab")
    }

    public func channelMore(continuation: String) async throws -> Page<SearchItem> {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.channelMore")
    }

    public func playlist(id: String) async throws -> PlaylistPage {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.playlist")
    }

    public func playlistMore(continuation: String) async throws -> Page<VideoSummary> {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.playlistMore")
    }

    public func resolve(url: URL) async throws -> ResolvedURL? {
        throw NoSlopError.notImplemented("InnerTubeYouTubeService.resolve")
    }
}
