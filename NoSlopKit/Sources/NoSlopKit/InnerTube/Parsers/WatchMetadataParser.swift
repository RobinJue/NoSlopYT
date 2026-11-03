import Foundation

/// Parses the metadata part of a `next` response (title, channel, counts, description with links, chapters,
/// comments token). `related` is left empty; `RelatedParser` fills it.
///
/// The data lives in `contents.twoColumnWatchNextResults.results.results.contents[]`
/// (`videoPrimaryInfoRenderer`: title, views, date, likes; `videoSecondaryInfoRenderer`: channel and description),
/// in `playerOverlays` (chapters) and in the comments section / engagement panel (comments token and count).
/// The renderers are looked up by name rather than by position, because other renderers (for example a
/// `ticketShelfRenderer`) can come first.
///
/// Every part is optional: a part that is missing or has an unexpected shape stays at its default and the rest of
/// the page still parses. Only a response without any title gives nil.
public enum WatchMetadataParser {
    public static func parse(_ json: JSON, videoID: String) -> VideoDetails? {
        let primary = json.first("videoPrimaryInfoRenderer")
        let secondary = json.first("videoSecondaryInfoRenderer")

        // Without the primary renderer the player overlay still carries the title.
        guard let title = trimmed(InnerTubeText.text(primary?["title"]))
            ?? trimmed(InnerTubeText.text(json.first("playerOverlayVideoDetailsRenderer")?["title"]))
        else { return nil }

        let views = primary?["viewCount"]?["videoViewCountRenderer"]
        let viewCountText = InnerTubeText.text(views?["viewCount"])
        let owner = secondary?["owner"]?["videoOwnerRenderer"]
        let likeInfo = likes(in: primary)

        return VideoDetails(
            id: videoID,
            title: title,
            channel: channel(from: owner),
            subscriberCountText: InnerTubeText.text(owner?["subscriberCountText"]),
            viewCount: InnerTubeText.parseCount(viewCountText),
            viewCountText: viewCountText,
            shortViewCountText: InnerTubeText.text(views?["shortViewCount"]),
            dateText: InnerTubeText.text(primary?["dateText"]),
            relativeDateText: InnerTubeText.text(primary?["relativeDateText"]),
            likeCount: likeInfo.count,
            likeCountText: likeInfo.text,
            description: description(from: secondary, videoID: videoID),
            chapters: chapters(in: json),
            commentCountText: commentCountText(in: json),
            commentsContinuation: commentsContinuation(in: json),
            isLive: views?["isLive"]?.bool ?? false
        )
    }

    // MARK: Likes

    /// The like button's title is the rounded count ("110K"); its accessibility text has the exact one
    /// ("like this video along with 110,320 other people"). A button without a number (likes hidden) gives neither.
    private static func likes(in primary: JSON?) -> (text: String?, count: Int?) {
        let buttons = primary?["videoActions"]?["menuRenderer"]?["topLevelButtons"]?.array ?? []
        for button in buttons {
            guard let like = button["segmentedLikeDislikeButtonViewModel"]?["likeButtonViewModel"] else { continue }
            let toggle = like["likeButtonViewModel"]?["toggleButtonViewModel"]?["toggleButtonViewModel"]
            let model = toggle?["defaultButtonViewModel"]?["buttonViewModel"] ?? like.first("buttonViewModel")
            guard let model,
                  let title = trimmed(model["title"]?.string),
                  title.contains(where: \.isNumber) else { continue }

            let rounded = InnerTubeText.parseCount(title)
            let exact = model["accessibilityText"]?.string.flatMap(firstCount(in:))
            return (title, exactCount(exact, agreeingWith: rounded) ?? rounded)
        }
        return (nil, nil)
    }

    /// The number the text starts counting at its first digit ("… along with 110,320 other people" → 110320).
    private static func firstCount(in text: String) -> Int? {
        guard let start = text.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return nil }
        return InnerTubeText.parseCount(String(text[start...]))
    }

    /// Trust the exact count only when it fits the rounded one (within 10 %, at least 1), so a number from some
    /// other part of the sentence never replaces the real one.
    private static func exactCount(_ exact: Int?, agreeingWith rounded: Int?) -> Int? {
        guard let exact, let rounded, exact >= 0 else { return nil }
        return abs(exact - rounded) <= max(rounded / 10, 1) ? exact : nil
    }

    // MARK: Channel

    private static func channel(from owner: JSON?) -> ChannelRef {
        guard let owner else { return ChannelRef(id: "", name: "") }
        let ownerEndpoint = owner["navigationEndpoint"]?["browseEndpoint"]
        let titleEndpoint = owner["title"]?["runs"]?[0]?["navigationEndpoint"]?["browseEndpoint"]
        // The title run's endpoint can use the /channel/UC… URL while the owner's has the @handle.
        let channelHandle = [ownerEndpoint, titleEndpoint].lazy
            .compactMap { handle(fromCanonicalPath: $0?["canonicalBaseUrl"]?.string) }
            .first
        return ChannelRef(
            id: ownerEndpoint?["browseId"]?.string ?? titleEndpoint?["browseId"]?.string ?? "",
            name: InnerTubeText.text(owner["title"]) ?? "",
            avatarURL: InnerTubeText.thumbnails(owner["thumbnail"]).best(minWidth: 176)?.url,
            handle: channelHandle
        )
    }

    /// "/@BlenderOfficial" → "@BlenderOfficial"; "/channel/UC…" and other legacy URLs have no handle.
    private static func handle(fromCanonicalPath path: String?) -> String? {
        guard let path, path.hasPrefix("/@") else { return nil }
        let name = path.dropFirst().prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let handle = String(name).removingPercentEncoding ?? String(name)
        return handle.count > 1 ? handle : nil
    }

    // MARK: Description

    private static func description(from secondary: JSON?, videoID: String) -> AttributedDescription {
        if let attributed = secondary?["attributedDescription"],
           let content = attributed["content"]?.string, !content.isEmpty {
            return AttributedDescription(
                text: content,
                links: descriptionLinks(in: content, runs: attributed["commandRuns"]?.array ?? [], videoID: videoID)
            )
        }
        // Older layout: a plain `description` text node without links.
        if let plain = InnerTubeText.text(secondary?["description"]) {
            return AttributedDescription(text: plain)
        }
        return .empty
    }

    /// One link per `commandRuns` entry that maps to a target. `startIndex` and `length` are UTF-16 offsets into
    /// `content` (protobuf JSON omits a zero `startIndex`); a run outside the text, or one with a command we don't
    /// know, is skipped.
    private static func descriptionLinks(in content: String, runs: [JSON], videoID: String) -> [DescriptionLink] {
        let totalLength = content.utf16.count
        var links: [DescriptionLink] = []
        for run in runs {
            var start = 0
            if let node = run["startIndex"] {
                guard let value = node.int else { continue }
                start = value
            }
            guard let length = run["length"]?.int, length > 0, start >= 0, start <= totalLength - length,
                  let command = run["onTap"]?["innertubeCommand"] else { continue }
            let range = start..<(start + length)
            let visibleText = { text(in: content, utf16Range: range) }
            guard let linkTarget = target(of: command, videoID: videoID, visibleText: visibleText) else { continue }
            links.append(DescriptionLink(range: range, target: linkTarget))
        }
        return links
    }

    private static func text(in content: String, utf16Range range: Range<Int>) -> String {
        let units = content.utf16
        let lower = units.index(units.startIndex, offsetBy: range.lowerBound)
        let upper = units.index(lower, offsetBy: range.count)
        return String(units[lower..<upper]) ?? ""
    }

    private static func target(of command: JSON, videoID: String, visibleText: () -> String) -> DescriptionLink.Target? {
        if let url = command["urlEndpoint"]?["url"]?.string {
            return urlTarget(url)
        }
        if let watch = command["watchEndpoint"] {
            return watchTarget(watch, videoID: videoID)
        }
        if let browse = command["browseEndpoint"] {
            return browseTarget(browse, command: command, visibleText: visibleText)
        }
        // Several commands run on tap: the first one that links somewhere wins.
        for wrapper in ["commandExecutorCommand", "serialCommand"] {
            for inner in command[wrapper]?["commands"]?.array ?? [] {
                if let found = target(of: inner["innertubeCommand"] ?? inner, videoID: videoID, visibleText: visibleText) {
                    return found
                }
            }
        }
        return nil
    }

    /// `https://www.youtube.com/redirect?…&q=<real address>` is unwrapped; `/hashtag/<tag>` is a hashtag; anything
    /// that is not an http(s) address is dropped.
    private static func urlTarget(_ raw: String) -> DescriptionLink.Target? {
        var address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("//") {
            address = "https:" + address
        } else if address.hasPrefix("/") {
            address = "https://www.youtube.com" + address
        }
        guard let components = URLComponents(string: address) else { return nil }

        if let host = components.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if components.path == "/redirect", let real = components.queryItems?.first(where: { $0.name == "q" })?.value {
                return webURL(URL(string: real)).map { .url($0) }
            }
            if let tag = hashtag(inPath: components.path) { return .hashtag(tag) }
        }
        return webURL(components.url).map { .url($0) }
    }

    private static func webURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func hashtag(inPath path: String) -> String? {
        guard path.hasPrefix("/hashtag/") else { return nil }
        let name = path.dropFirst("/hashtag/".count).prefix { $0 != "/" }
        return name.isEmpty ? nil : String(name)
    }

    /// A link to the same video is a timestamp (no `startTimeSeconds` means the start); to another video it is a
    /// video link; a playlist-only link is a playlist.
    private static func watchTarget(_ watch: JSON, videoID: String) -> DescriptionLink.Target? {
        let start = watch["startTimeSeconds"]?.int.map { max($0, 0) }
        if let id = watch["videoId"]?.string, !id.isEmpty {
            return id == videoID ? .timestamp(seconds: start ?? 0) : .video(id: id, startSeconds: start)
        }
        if let playlist = watch["playlistId"]?.string, !playlist.isEmpty {
            return .playlist(id: playlist)
        }
        return nil
    }

    /// `UC…` is a channel (a mention), `VL…` a playlist, `FEhashtag` a hashtag whose name is in the command's URL
    /// (`/hashtag/<tag>`) or, failing that, in the visible text.
    private static func browseTarget(_ browse: JSON, command: JSON, visibleText: () -> String) -> DescriptionLink.Target? {
        guard let browseID = browse["browseId"]?.string else { return nil }
        if browseID.hasPrefix("UC") {
            return .channel(id: browseID)
        }
        if browseID.hasPrefix("VL"), browseID.count > 2 {
            return .playlist(id: String(browseID.dropFirst(2)))
        }
        if browseID == "FEhashtag" {
            let metadataURL = command["commandMetadata"]?["webCommandMetadata"]?["url"]?.string
            for path in [metadataURL, browse["canonicalBaseUrl"]?.string].compactMap({ $0 }) {
                if let tag = hashtag(inPath: URLComponents(string: path)?.path ?? path) { return .hashtag(tag) }
            }
            let shown = visibleText().trimmingCharacters(in: .whitespacesAndNewlines)
            if shown.hasPrefix("#"), shown.count > 1, !shown.contains(where: \.isWhitespace) {
                return .hashtag(shown.dropFirst().lowercased())
            }
        }
        return nil
    }

    // MARK: Chapters

    /// `playerOverlays…multiMarkersPlayerBarRenderer.markersMap[]`: the chapters the author wrote
    /// (`DESCRIPTION_CHAPTERS`), else YouTube's own (`AUTO_CHAPTERS`). Other marker groups (most replayed) are ignored.
    private static func chapters(in json: JSON) -> [Chapter] {
        let markers = json.findAll("markersMap").flatMap { $0.array ?? [] }
        for key in ["DESCRIPTION_CHAPTERS", "AUTO_CHAPTERS"] {
            let list = markers.first { $0["key"]?.string == key }?["value"]?["chapters"]?.array ?? []
            let chapters = list.compactMap { chapter(from: $0["chapterRenderer"]) }
            if !chapters.isEmpty {
                // Chapter lists are ordered already; sorting only guards the lookup by time against an odd response.
                return chapters.enumerated()
                    .sorted { ($0.element.startSeconds, $0.offset) < ($1.element.startSeconds, $1.offset) }
                    .map(\.element)
            }
        }
        return []
    }

    private static func chapter(from renderer: JSON?) -> Chapter? {
        guard let renderer,
              let title = trimmed(InnerTubeText.text(renderer["title"])),
              let millis = renderer["timeRangeStartMillis"]?.double, millis.isFinite, millis >= 0 else { return nil }
        return Chapter(
            title: title,
            startSeconds: millis / 1000,
            thumbnailURL: InnerTubeText.thumbnails(renderer["thumbnail"]).last?.url      // the widest rendition
        )
    }

    // MARK: Comments

    /// The token that loads the first page of comments: the `continuationItemRenderer` of the in-page section with
    /// `sectionIdentifier == "comment-item-section"`. The engagement panel has one too (searched after the page,
    /// because `contents` comes before `engagementPanels`).
    private static func commentsContinuation(in json: JSON) -> String? {
        let sections = json.findAll("itemSectionRenderer")
            .filter { $0["sectionIdentifier"]?.string == "comment-item-section" }
        for section in sections {
            for item in section["contents"]?.array ?? [] {
                if let renderer = item["continuationItemRenderer"],
                   let token = CommentsParser.continuationToken(of: renderer) {
                    return token
                }
            }
        }
        return nil
    }

    /// The short comment count ("5.2K") shown next to "Comments": the header of the comments engagement panel, or the
    /// entry-point header some layouts use.
    private static func commentCountText(in json: JSON) -> String? {
        var candidates: [JSON?] = []
        for panel in json["engagementPanels"]?.array ?? [] {
            guard let renderer = panel["engagementPanelSectionListRenderer"],
                  renderer["panelIdentifier"]?.string == "engagement-panel-comments-section" else { continue }
            candidates.append(renderer["header"]?["engagementPanelTitleHeaderRenderer"]?["contextualInfo"])
        }
        candidates.append(json.first("commentsEntryPointHeaderRenderer")?["commentCount"])
        return candidates
            .lazy
            .compactMap { trimmed(InnerTubeText.text($0)) }
            .first { text in text.contains(where: \.isNumber) }
    }

    // MARK: Helpers

    private static func trimmed(_ string: String?) -> String? {
        guard let value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
