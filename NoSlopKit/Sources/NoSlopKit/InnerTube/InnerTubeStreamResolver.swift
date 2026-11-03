import Foundation

/// `StreamResolving` backed by the `player` endpoint with the visionOS client profile.
///
/// A bot check (`NoSlopError.botCheck`) means YouTube rejected the visitorData that was sent. The resolver fetches a
/// fresh one and asks once more; a second bot check is thrown to the caller, whose message offers "Open on YouTube".
/// Every call resolves afresh: stream URLs expire and playback recovery relies on getting new ones.
public struct InnerTubeStreamResolver: StreamResolving {
    private let client: InnerTubeClient
    private let now: @Sendable () -> Date

    public init(client: InnerTubeClient) {
        self.init(client: client, now: { Date() })
    }

    /// Tests inject the clock that `StreamInfo.expiresAt` is measured from.
    init(client: InnerTubeClient, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.now = now
    }

    public func streamInfo(videoID: String) async throws -> StreamInfo {
        do {
            return try await resolve(videoID)
        } catch NoSlopError.botCheck {
            _ = try await client.visitorData(forceRefresh: true)
            return try await resolve(videoID)
        }
    }

    private func resolve(_ videoID: String) async throws -> StreamInfo {
        let response = try await client.post(
            endpoint: "player",
            profile: .visionOS,
            body: [
                "videoId": .string(videoID),
                "contentCheckOk": true,
                "racyCheckOk": true,
                "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
            ]
        )
        return try PlayerResponseParser.parse(response, now: now())
    }
}
