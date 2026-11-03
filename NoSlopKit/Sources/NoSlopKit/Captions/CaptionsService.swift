import Foundation

/// `CaptionsProviding` over HTTP: fetches a track's WebVTT (`baseURL + "&fmt=vtt"`) and parses it.
///
/// STUB (Task 1A). Task 2 owns this file: `cues(for:)` throws `NoSlopError.notImplemented`.
public struct CaptionsService: CaptionsProviding {
    public init(http: any HTTPClient) {}

    public func cues(for track: CaptionTrack) async throws -> [CaptionCue] {
        throw NoSlopError.notImplemented("CaptionsService.cues")
    }
}
