import Foundation

/// Maps individual InnerTube renderers (`videoRenderer`, `lockupViewModel`, ...) to models, dropping ads and AI blocks.
///
/// STUB (Task 1A). Task 3 owns this file: nothing is parsed until it is filled in.
public enum ItemParser {
    /// Harvests every video, channel and playlist under `json` in document order, dropping ads and AI summaries.
    public static func items(in json: JSON) -> [SearchItem] {
        []
    }

    public static func video(fromVideoRenderer json: JSON) -> VideoSummary? {
        nil
    }

    public static func video(fromLockup json: JSON) -> VideoSummary? {
        nil
    }

    public static func playlist(fromLockup json: JSON) -> PlaylistSummary? {
        nil
    }

    public static func short(fromShortsLockup json: JSON) -> VideoSummary? {
        nil
    }

    public static func channel(fromChannelRenderer json: JSON) -> ChannelSummary? {
        nil
    }
}
