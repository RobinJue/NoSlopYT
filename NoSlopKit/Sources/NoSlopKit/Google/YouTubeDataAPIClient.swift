import Foundation

/// `YouTubeAccountService` over the official YouTube Data API v3 with the user's OAuth token.
///
/// STUB (Task 1A). Task 5 owns this file: every member throws `NoSlopError.notImplemented`.
public struct YouTubeDataAPIClient: YouTubeAccountService {
    public init(http: any HTTPClient, auth: any GoogleAuthProviding) {}

    public func subscriptions() async throws -> [SubscribedChannel] {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.subscriptions")
    }

    public func subscribe(channelID: String) async throws -> String {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.subscribe")
    }

    public func unsubscribe(subscriptionID: String) async throws {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.unsubscribe")
    }

    public func myPlaylists() async throws -> [PlaylistSummary] {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.myPlaylists")
    }

    public func playlistItems(playlistID: String, pageToken: String?) async throws -> Page<VideoSummary> {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.playlistItems")
    }

    public func likedVideos(pageToken: String?) async throws -> Page<VideoSummary> {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.likedVideos")
    }

    public func rating(videoID: String) async throws -> VideoRating {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.rating")
    }

    public func rate(videoID: String, rating: VideoRating) async throws {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.rate")
    }

    public func addToPlaylist(videoID: String, playlistID: String) async throws {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.addToPlaylist")
    }

    public func durations(videoIDs: [String]) async throws -> [String: Int] {
        throw NoSlopError.notImplemented("YouTubeDataAPIClient.durations")
    }
}
