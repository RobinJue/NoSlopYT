import Foundation

/// Parses the "up next" videos of a `next` response and its continuations.
///
/// Only videos come back (a related list can carry playlists and courses too). Shorts are kept, flagged with
/// `isShort`, but sit behind the regular videos: a `next` response puts a Shorts shelf above the list, and the first
/// item of an "up next" list has to be a real video.
public enum RelatedParser {
    public static func parse(next json: JSON) -> Page<VideoSummary> {
        let secondary = json["contents"]?["twoColumnWatchNextResults"]?["secondaryResults"]
        return page(from: secondary?["secondaryResults"]?["results"] ?? secondary ?? json["contents"]?.first("secondaryResults"))
    }

    public static func parseContinuation(_ json: JSON) -> Page<VideoSummary> {
        page(from: ItemParser.continuationItems(in: json))
    }

    private static func page(from scope: JSON?) -> Page<VideoSummary> {
        guard let scope else { return Page() }
        let found = ItemParser.harvest(scope)
        let videos = found.items.compactMap(\.video)
        return Page(items: videos.filter { !$0.isShort } + videos.filter { $0.isShort }, continuation: found.continuation)
    }
}
