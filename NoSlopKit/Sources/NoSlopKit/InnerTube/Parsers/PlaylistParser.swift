import Foundation

/// Parses `browse` responses for playlist pages and their continuations.
///
/// The header (title, owner, count, description) and the videos of the first page come from one response; the rest
/// of the videos follow through the continuation token. A response without a header still gives its videos, and one
/// with neither is nil.
public enum PlaylistParser {
    public static func parse(_ json: JSON, playlistID: String) -> PlaylistPage? {
        guard let scope = ChannelParser.selectedTabContent(in: json) ?? json["contents"] else { return nil }
        let found = ItemParser.harvest(scope)
        let videos = found.items.compactMap(\.video)
        let header = parseHeader(json)
        guard header.title != nil || !videos.isEmpty else { return nil }

        let thumbnails = header.thumbnails.isEmpty ? (videos.first?.thumbnails ?? []) : header.thumbnails
        return PlaylistPage(
            info: PlaylistSummary(
                id: playlistID,
                title: header.title ?? "",
                channel: header.channel,
                thumbnails: thumbnails,
                videoCount: ItemParser.itemCount(from: header.countText),
                videoCountText: header.countText
            ),
            description: header.description,
            videos: Page(items: videos, continuation: found.continuation)
        )
    }

    public static func parseContinuation(_ json: JSON) -> Page<VideoSummary> {
        guard let items = ItemParser.continuationItems(in: json) else { return Page() }
        let found = ItemParser.harvest(items)
        return Page(items: found.items.compactMap(\.video), continuation: found.continuation)
    }

    // MARK: Header

    private struct Header {
        var title: String?
        var description: String?
        var channel: ChannelRef?
        var thumbnails: [Thumbnail] = []
        var countText: String?
    }

    /// The new `pageHeaderViewModel`, with the metadata renderer, the microformat and the older sidebar as fallbacks.
    private static func parseHeader(_ json: JSON) -> Header {
        let model = json["header"]?["pageHeaderRenderer"]?["content"]?["pageHeaderViewModel"]
        let meta = json["metadata"]?["playlistMetadataRenderer"]
        let micro = json["microformat"]?["microformatDataRenderer"]
        let sidebarItems = json["sidebar"]?["playlistSidebarRenderer"]?["items"]?.array ?? []
        let primary = sidebarItems.lazy.compactMap { $0["playlistSidebarPrimaryInfoRenderer"] }.first
        let secondary = sidebarItems.lazy.compactMap { $0["playlistSidebarSecondaryInfoRenderer"] }.first

        var header = Header()
        let titleNode = model?["title"]?["dynamicTextViewModel"]?["text"]
        header.title = ItemParser.clean(InnerTubeText.text(titleNode))
            ?? ItemParser.clean(meta?["title"]?.string)
            ?? ItemParser.clean(InnerTubeText.text(primary?["title"]))
            ?? ItemParser.clean(micro?["title"]?.string)
        let preview = model?["description"]?["descriptionPreviewViewModel"]?["description"]
        header.description = ItemParser.clean(InnerTubeText.text(preview))
            ?? ItemParser.clean(meta?["description"]?.string)
        header.channel = owner(model: model, sidebar: secondary)

        // Thumbnails: the header artwork and the microformat image, smallest first.
        let artwork = InnerTubeText.thumbnails(model?["heroImage"]?["contentPreviewImageViewModel"]?["image"])
            + InnerTubeText.thumbnails(micro?["thumbnail"])
        var seen = Set<URL>()
        header.thumbnails = artwork.filter { seen.insert($0.url).inserted }
            .enumerated()
            .sorted { lhs, rhs in
                let l = lhs.element.width ?? 0
                let r = rhs.element.width ?? 0
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map { $0.element }

        // The count: "14 videos" in the metadata row of the header, or the first of the sidebar's stats.
        let rows = model?["metadata"]?["contentMetadataViewModel"]?["metadataRows"]?.array ?? []
        let parts = rows.flatMap { row in
            (row["metadataParts"]?.array ?? []).compactMap { ItemParser.clean(InnerTubeText.text($0["text"])) }
        }
        header.countText = parts.first(where: isCount) ?? ItemParser.clean(InnerTubeText.text(primary?["stats"]?[0]))
        return header
    }

    private static let countWords: Set<String> = ["video", "videos", "episode", "episodes", "lesson", "lessons"]

    /// "14 videos", "8 lessons": a number next to the word for what is counted.
    private static func isCount(_ text: String) -> Bool {
        guard text.contains(where: \.isNumber) else { return false }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains { countWords.contains($0) }
    }

    /// The playlist's owner: the sidebar's `videoOwnerRenderer` (name, id, handle and avatar in one place), else the
    /// avatar stack of the header ("by Ryan King Art").
    private static func owner(model: JSON?, sidebar: JSON?) -> ChannelRef? {
        if let owner = sidebar?["videoOwner"]?["videoOwnerRenderer"] {
            let run = owner["title"]?["runs"]?[0]
            let endpoint = run?["navigationEndpoint"]?["browseEndpoint"] ?? owner["navigationEndpoint"]?["browseEndpoint"]
            if let name = ItemParser.clean(run?["text"]?.string), let id = ItemParser.channelID(endpoint?["browseId"]?.string) {
                return ChannelRef(
                    id: id,
                    name: name,
                    avatarURL: InnerTubeText.thumbnails(owner["thumbnail"]).last?.url,
                    handle: ItemParser.handle(fromPath: endpoint?["canonicalBaseUrl"]?.string)
                )
            }
        }

        let stack = model?.first("avatarStackViewModel")
        let endpoint = stack?["text"]?.first("browseEndpoint")
        guard var name = ItemParser.clean(InnerTubeText.text(stack?["text"])),
              let id = ItemParser.channelID(endpoint?["browseId"]?.string)
        else { return nil }
        if name.lowercased().hasPrefix("by ") {
            name = ItemParser.clean(String(name.dropFirst(3))) ?? name
        }
        let avatars = (stack?["avatars"]?.array ?? []).flatMap { InnerTubeText.thumbnails($0["avatarViewModel"]?["image"]) }
        return ChannelRef(
            id: id,
            name: name,
            avatarURL: avatars.last?.url,
            handle: ItemParser.handle(fromPath: endpoint?["canonicalBaseUrl"]?.string)
        )
    }
}
