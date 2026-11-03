import Foundation

/// DeArrow community titles through the 4-hex-character hash-prefix endpoint.
///
/// STUB (Task 1A). Task 6 owns this file: `betterTitle` returns nil until it is filled in.
public actor DeArrowClient: DeArrowProviding {
    public init(http: any HTTPClient, baseURL: URL = URL(string: "https://sponsor.ajay.app")!) {}

    public func betterTitle(videoID: String) async -> String? {
        nil
    }
}
