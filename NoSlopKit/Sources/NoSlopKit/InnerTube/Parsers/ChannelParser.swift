import Foundation

/// Parses `browse` responses for channel pages, channel tabs and their continuations.
///
/// A channel response holds the header, the list of tabs and the content of the selected tab only; everything is read
/// from those places (a channel's "about" panel inside the header carries a continuation of its own, and must not be
/// mistaken for the grid's).
public enum ChannelParser {
    /// The `browse` `params` value that selects each channel tab.
    public static let tabParams: [ChannelTabKind: String] = [
        .videos: "EgZ2aWRlb3PyBgQKAjoA",
        .live: "EgdzdHJlYW1z8gYECgJ6AA%3D%3D",
        .playlists: "EglwbGF5bGlzdHPyBgoKCEIGCgIQaCIA",
    ]

    /// The channel header, the tabs and the videos (or whatever the selected tab holds). Nil when the response has no
    /// recognisable channel header (no id or no name).
    public static func parseChannelPage(_ json: JSON) -> ChannelPage? {
        guard let header = parseHeader(json) else { return nil }
        return ChannelPage(header: header, availableTabs: availableTabs(in: json), videos: tabPage(in: json, channel: header.ref))
    }

    /// The items of the selected tab: a video grid (Videos, Live, Shorts) or a list of playlists.
    public static func parseTab(_ json: JSON) -> Page<SearchItem> {
        tabPage(in: json, channel: parseHeader(json)?.ref)
    }

    /// More items of a tab, from `onResponseReceivedActions[].appendContinuationItemsAction`.
    public static func parseContinuation(_ json: JSON) -> Page<SearchItem> {
        guard let items = ItemParser.continuationItems(in: json) else { return Page() }
        let found = ItemParser.harvest(items)
        return Page(items: found.items, continuation: found.continuation)
    }

    // MARK: Tabs

    /// Tabs are recognised by the start of their `params`, not by title (titles are localized).
    private static let tabPrefixes: [ChannelTabKind: String] = [
        .videos: "EgZ2aWRlb3",
        .live: "EgdzdHJlYW1z",
        .playlists: "EglwbGF5bGlzdH",
    ]

    private static func tabs(in json: JSON) -> [JSON] {
        (json["contents"]?.first("tabs")?.array ?? []).compactMap { $0["tabRenderer"] }
    }

    /// Videos, Live and Playlists, in that order, for those the channel has.
    private static func availableTabs(in json: JSON) -> [ChannelTabKind] {
        let params = tabs(in: json).compactMap { $0["endpoint"]?["browseEndpoint"]?["params"]?.string }
        return ChannelTabKind.allCases.filter { kind in
            guard let prefix = tabPrefixes[kind] else { return false }
            return params.contains { $0.hasPrefix(prefix) }
        }
    }

    /// The content of the tab marked `selected` (else the first one that has content). Shared with the playlist parser.
    static func selectedTabContent(in json: JSON) -> JSON? {
        let renderers = tabs(in: json)
        let selected = renderers.first { $0["selected"]?.bool == true } ?? renderers.first { $0["content"] != nil }
        return selected?["content"]
    }

    private static func tabPage(in json: JSON, channel: ChannelRef?) -> Page<SearchItem> {
        guard let scope = selectedTabContent(in: json) ?? json["contents"] else { return Page() }
        let found = ItemParser.harvest(scope)
        return Page(items: attach(channel, to: found.items), continuation: found.continuation)
    }

    /// Channel tabs list their items without a channel name (every item is the channel's own): fill it in.
    private static func attach(_ channel: ChannelRef?, to items: [SearchItem]) -> [SearchItem] {
        guard let channel else { return items }
        return items.map { item in
            switch item {
            case .video(var video):
                video.channel = video.channel ?? channel
                return .video(video)
            case .playlist(var playlist):
                playlist.channel = playlist.channel ?? channel
                return .playlist(playlist)
            case .channel:
                return item
            }
        }
    }

    // MARK: Header

    /// From `header.pageHeaderRenderer.content.pageHeaderViewModel`; the id comes from `metadata.channelMetadataRenderer`.
    /// The older `c4TabbedHeaderRenderer` is read as a fallback.
    static func parseHeader(_ json: JSON) -> ChannelHeader? {
        let model = json["header"]?["pageHeaderRenderer"]?["content"]?["pageHeaderViewModel"]
        let meta = json["metadata"]?["channelMetadataRenderer"]
        let legacy = json["header"]?["c4TabbedHeaderRenderer"]

        let id = ItemParser.channelID(meta?["externalId"]?.string)
            ?? ItemParser.channelID(legacy?["channelId"]?.string)
            ?? channelID(inURL: meta?["channelUrl"]?.string)
            ?? channelID(inURL: meta?["rssUrl"]?.string)
        let name = ItemParser.clean(InnerTubeText.text(model?["title"]?["dynamicTextViewModel"]?["text"]))
            ?? ItemParser.clean(meta?["title"]?.string)
            ?? ItemParser.clean(InnerTubeText.text(legacy?["title"]))
        guard let id, let name else { return nil }

        // Metadata rows: "@handle", then "1.25M subscribers", "1.5K videos" (in rows, or all in one).
        let rows = model?["metadata"]?["contentMetadataViewModel"]?["metadataRows"]?.array ?? []
        let parts = rows.flatMap { row in
            (row["metadataParts"]?.array ?? []).compactMap { ItemParser.clean(InnerTubeText.text($0["text"])) }
        }
        let handleText = parts.first { $0.hasPrefix("@") }
        let counts = parts.filter { !$0.hasPrefix("@") }
        var subscribers = counts.first { text in words(in: text).contains { $0.hasPrefix("subscriber") } }
        var videos = counts.first { text in words(in: text).contains { $0 == "video" || $0 == "videos" } }
        // A language without these words: "<subscribers> · <videos>" is YouTube's order. Some languages share one of
        // them ("Videos" in German and Spanish, "video" in Italian) and not the other ("Abonnenten"): when two counts
        // are shown and one is known, the other one is the remaining count.
        if counts.count == 2 {
            switch (subscribers, videos) {
            case (nil, nil):
                subscribers = counts[0]
                videos = counts[1]
            case (nil, let known?):
                subscribers = counts.first { $0 != known }
            case (let known?, nil):
                videos = counts.first { $0 != known }
            default:
                break
            }
        }

        let avatarNode = model?["image"]?["decoratedAvatarViewModel"]?["avatar"]?["avatarViewModel"]?["image"]
        let avatars = InnerTubeText.thumbnails(avatarNode)
        let banners = InnerTubeText.thumbnails(model?["banner"]?["imageBannerViewModel"]?["image"])
        let legacyPath = legacy?["navigationEndpoint"]?["browseEndpoint"]?["canonicalBaseUrl"]?.string
        let preview = model?["description"]?["descriptionPreviewViewModel"]?["description"]

        return ChannelHeader(
            id: id,
            name: name,
            handle: handleText
                ?? ItemParser.handle(fromPath: meta?["vanityChannelUrl"]?.string)
                ?? ItemParser.handle(fromPath: legacyPath),
            avatarURL: (avatars.isEmpty ? InnerTubeText.thumbnails(legacy?["avatar"]) : avatars).last?.url,
            bannerURL: (banners.isEmpty ? InnerTubeText.thumbnails(legacy?["banner"]) : banners).best(minWidth: 1280)?.url,
            subscriberCountText: subscribers ?? ItemParser.clean(InnerTubeText.text(legacy?["subscriberCountText"])),
            videoCountText: videos ?? ItemParser.clean(InnerTubeText.text(legacy?["videosCountText"])),
            description: ItemParser.clean(InnerTubeText.text(preview))
                ?? ItemParser.clean(meta?["description"]?.string)
                ?? ItemParser.clean(legacy?["tagline"]?["channelTaglineRenderer"]?["content"]?.string)
        )
    }

    private static func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// "UC…" out of ".../channel/UC…" or ".../videos.xml?channel_id=UC…".
    private static func channelID(inURL url: String?) -> String? {
        guard let url else { return nil }
        for marker in ["/channel/", "channel_id="] {
            guard let range = url.range(of: marker) else { continue }
            let rest = url[range.upperBound...]
            let id = rest.prefix { $0 != "/" && $0 != "?" && $0 != "&" && $0 != "#" }
            if let found = ItemParser.channelID(String(id)) { return found }
        }
        return nil
    }
}
