import Foundation

/// SponsorBlock segment lookups through the 4-hex-character hash-prefix endpoint.
///
/// STUB (Task 1A). Task 6 owns this file: `segments` throws `NoSlopError.notImplemented`.
public actor SponsorBlockClient: SponsorBlockProviding {
    public init(http: any HTTPClient, baseURL: URL = URL(string: "https://sponsor.ajay.app")!) {}

    public func segments(videoID: String) async throws -> [SponsorSegment] {
        throw NoSlopError.notImplemented("SponsorBlockClient.segments")
    }
}
