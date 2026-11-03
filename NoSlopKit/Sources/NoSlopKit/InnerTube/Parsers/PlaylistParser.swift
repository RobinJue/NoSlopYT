import Foundation

/// Parses `browse` responses for playlist pages and their continuations.
///
/// STUB (Task 1A). Task 3 owns this file: returns nil / an empty page until it is filled in.
public enum PlaylistParser {
    public static func parse(_ json: JSON, playlistID: String) -> PlaylistPage? {
        nil
    }

    public static func parseContinuation(_ json: JSON) -> Page<VideoSummary> {
        Page()
    }
}
