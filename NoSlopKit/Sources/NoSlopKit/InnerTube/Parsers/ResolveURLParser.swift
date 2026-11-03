import Foundation

/// Parses a `navigation/resolve_url` response into what the URL points at.
///
/// The answer is an endpoint: `watchEndpoint` for a video, `browseEndpoint` for a channel (`UC…`) or a playlist
/// (`VL<playlist id>`). Everything else, such as an external `urlEndpoint` or a hashtag page, gives nil.
public enum ResolveURLParser {
    public static func parse(_ json: JSON) -> ResolvedURL? {
        let endpoint = json["endpoint"] ?? json

        if let watch = endpoint["watchEndpoint"],
           let id = watch["videoId"]?.string, !id.isEmpty {
            return .video(id: id, startSeconds: watch["startTimeSeconds"]?.int)
        }

        if let browseID = endpoint["browseEndpoint"]?["browseId"]?.string {
            if browseID.hasPrefix("UC"), browseID.count > 2 {
                return .channel(id: browseID)
            }
            if browseID.hasPrefix("VL"), browseID.count > 2 {
                return .playlist(id: String(browseID.dropFirst(2)))
            }
        }
        return nil
    }
}
