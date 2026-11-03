import Foundation

/// `StreamResolving` backed by the `player` endpoint with the visionOS client profile.
///
/// STUB (Task 1A). Task 2 owns this file: `streamInfo` throws `NoSlopError.notImplemented`.
public struct InnerTubeStreamResolver: StreamResolving {
    public init(client: InnerTubeClient) {}

    public func streamInfo(videoID: String) async throws -> StreamInfo {
        throw NoSlopError.notImplemented("InnerTubeStreamResolver.streamInfo")
    }
}
