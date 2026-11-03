import Foundation

/// Parses the metadata part of a `next` response (title, channel, counts, description with links, chapters,
/// comments token). `related` is left empty; `RelatedParser` fills it.
///
/// STUB (Task 1A). Task 4 owns this file: returns nil until it is filled in.
public enum WatchMetadataParser {
    public static func parse(_ json: JSON, videoID: String) -> VideoDetails? {
        nil
    }
}
