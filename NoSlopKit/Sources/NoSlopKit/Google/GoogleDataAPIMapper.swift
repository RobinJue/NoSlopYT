import Foundation

/// Maps YouTube Data API v3 resources to the kit's models. Every function returns nil (or an empty list) for
/// anything it cannot make sense of instead of failing, so one odd item never loses the rest of a page.
enum GoogleDataAPIMapper {
    // MARK: Subscriptions

    /// `subscription` resource -> the channel subscribed to, remembering the subscription id (needed to unsubscribe).
    static func subscription(_ item: JSON) -> SubscribedChannel? {
        guard let subscriptionID = nonEmpty(item["id"]?.string),
              let channelID = nonEmpty(item["snippet"]?["resourceId"]?["channelId"]?.string)
        else { return nil }
        let snippet = item["snippet"]
        // The avatar is the "default" rendition; if YouTube leaves it out, the smallest one it sent.
        let avatar = GoogleURLs.web(snippet?["thumbnails"]?["default"]?["url"]?.string)
            ?? thumbnails(snippet?["thumbnails"]).first?.url
        return SubscribedChannel(
            id: channelID,
            name: snippet?["title"]?.string ?? "",
            avatarURL: avatar,
            source: .google(subscriptionID: subscriptionID),
            subscribedAt: date(snippet?["publishedAt"]?.string)
        )
    }

    // MARK: Playlists

    /// `playlist` resource (parts snippet, contentDetails).
    static func playlist(_ item: JSON) -> PlaylistSummary? {
        guard let id = nonEmpty(item["id"]?.string) else { return nil }
        let snippet = item["snippet"]
        return PlaylistSummary(
            id: id,
            title: snippet?["title"]?.string ?? "",
            channel: channelRef(id: snippet?["channelId"]?.string, name: snippet?["channelTitle"]?.string),
            thumbnails: thumbnails(snippet?["thumbnails"]),
            videoCount: item["contentDetails"]?["itemCount"]?.int
        )
    }

    /// `playlistItem` resource (parts snippet, contentDetails) -> the video it holds. Private and deleted videos stay
    /// in a playlist as placeholders ("Private video", "Deleted video", no owner); they are dropped here.
    static func playlistItemVideo(_ item: JSON) -> VideoSummary? {
        let snippet = item["snippet"]
        guard let videoID = nonEmpty(item["contentDetails"]?["videoId"]?.string) ?? nonEmpty(snippet?["resourceId"]?["videoId"]?.string) else {
            return nil
        }
        let ownerID = nonEmpty(snippet?["videoOwnerChannelId"]?.string)
        if ownerID == nil, isPlaceholder(title: snippet?["title"]?.string, description: snippet?["description"]?.string) {
            return nil
        }
        return VideoSummary(
            id: videoID,
            title: snippet?["title"]?.string ?? "",
            channel: channelRef(id: ownerID, name: snippet?["videoOwnerChannelTitle"]?.string),
            thumbnails: thumbnails(snippet?["thumbnails"]),
            publishedAt: date(item["contentDetails"]?["videoPublishedAt"]?.string)  // the upload date, not the date added
        )
    }

    private static func isPlaceholder(title: String?, description: String?) -> Bool {
        ["Private video", "Deleted video"].contains(title ?? "")
            || ["This video is private.", "This video is unavailable."].contains(description ?? "")
    }

    // MARK: Videos

    /// `video` resource (parts snippet, contentDetails, statistics).
    static func video(_ item: JSON) -> VideoSummary? {
        guard let id = nonEmpty(item["id"]?.string) else { return nil }
        let snippet = item["snippet"]
        let broadcast = snippet?["liveBroadcastContent"]?.string
        return VideoSummary(
            id: id,
            title: snippet?["title"]?.string ?? "",
            channel: channelRef(id: snippet?["channelId"]?.string, name: snippet?["channelTitle"]?.string),
            thumbnails: thumbnails(snippet?["thumbnails"]),
            durationSeconds: seconds(fromISO8601: item["contentDetails"]?["duration"]?.string),
            viewCount: item["statistics"]?["viewCount"]?.int,  // a string in the API; nil when the owner hides it
            publishedAt: date(snippet?["publishedAt"]?.string),
            isLive: broadcast == "live",
            isUpcoming: broadcast == "upcoming"
        )
    }

    /// The length in seconds, or nil when missing, unparsable or zero ("P0D" is what live streams and premieres report).
    static func seconds(fromISO8601 text: String?) -> Int? {
        guard let seconds = InnerTubeText.parseISO8601Duration(text), seconds > 0 else { return nil }
        return seconds
    }

    // MARK: Shared pieces

    private static let thumbnailRank: [String: Int] = [
        "default": 0, "medium": 1, "high": 2, "standard": 3, "maxres": 4, "fhd": 5, "qhd": 6, "uhd": 7,
    ]

    /// The `thumbnails` object ({"default": {url, width, height}, ...}) as a list, smallest first. Renditions without
    /// a width (subscription avatars) are ordered by their name; entries without a usable URL are skipped.
    static func thumbnails(_ node: JSON?) -> [Thumbnail] {
        guard let object = node?.object else { return [] }
        let entries: [(rank: Int, thumbnail: Thumbnail)] = object.compactMap { key, value in
            guard let url = GoogleURLs.web(value["url"]?.string) else { return nil }
            return (thumbnailRank[key] ?? Int.max, Thumbnail(url: url, width: value["width"]?.int, height: value["height"]?.int))
        }
        return entries
            .sorted { lhs, rhs in
                let (leftWidth, rightWidth) = (lhs.thumbnail.width ?? 0, rhs.thumbnail.width ?? 0)
                if leftWidth != rightWidth { return leftWidth < rightWidth }
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.thumbnail.url.absoluteString < rhs.thumbnail.url.absoluteString
            }
            .map(\.thumbnail)
    }

    private static func channelRef(id: String?, name: String?) -> ChannelRef? {
        guard let id = nonEmpty(id) else { return nil }
        return ChannelRef(id: id, name: name ?? "")
    }

    /// RFC 3339 timestamps as the API writes them: "2009-10-25T06:57:33Z", or with fractional seconds of any length
    /// ("2020-03-05T17:44:27.238162Z"), which are dropped (whole seconds are plenty here).
    static func date(_ text: String?) -> Date? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let timeStart = text.firstIndex(of: "T"), let dot = text[timeStart...].firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, let digit = text[end].asciiValue, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) {
                end = text.index(after: end)
            }
            text.removeSubrange(dot..<end)
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
