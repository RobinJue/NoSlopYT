import Foundation

/// Parses the "up next" videos of a `next` response and its continuations.
///
/// STUB (Task 1A). Task 3 owns this file: returns an empty page until it is filled in.
public enum RelatedParser {
    public static func parse(next json: JSON) -> Page<VideoSummary> {
        Page()
    }

    public static func parseContinuation(_ json: JSON) -> Page<VideoSummary> {
        Page()
    }
}
