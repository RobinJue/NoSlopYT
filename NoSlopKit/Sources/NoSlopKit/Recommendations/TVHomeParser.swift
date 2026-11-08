import Foundation

/// What the app needs to ask YouTube "not interested" for one Home card: the panel's tag and its params.
/// Both are request material, so neither is ever printed.
public struct TVCardHandle: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public let panelID: String
    public let params: String

    public init(panelID: String, params: String) {
        self.panelID = panelID
        self.params = params
    }

    public var description: String { "TVCardHandle(...)" }
    public var debugDescription: String { description }
}

/// One parsed page of YouTube's TV Home (a first page or a section continuation).
public struct TVHomeParse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// From the `GFEEDBACK` service params; nil when the reply does not say.
    public var loggedIn: Bool?
    /// Real videos only, in page order: no ads, promos, channels, paid items or Shorts.
    public var videos: [VideoSummary]
    /// The "not interested" handle of each video that has one, by video id.
    public var handles: [String: TVCardHandle]
    /// The token for the next page of sections; never printed.
    public var sectionContinuation: String?
    /// How many Shorts were seen (they are counted, not returned).
    public var shorts: Int
    /// What was left out on purpose, by renderer or reason (`adSlotRenderer`, `tile:CHANNEL`, `paid`, ...).
    public var skipped: [String: Int]
    /// Renderer names this parser does not know, counted and never shown.
    public var unknown: [String: Int]

    public init(
        loggedIn: Bool? = nil,
        videos: [VideoSummary] = [],
        handles: [String: TVCardHandle] = [:],
        sectionContinuation: String? = nil,
        shorts: Int = 0,
        skipped: [String: Int] = [:],
        unknown: [String: Int] = [:]
    ) {
        self.loggedIn = loggedIn
        self.videos = videos
        self.handles = handles
        self.sectionContinuation = sectionContinuation
        self.shorts = shorts
        self.skipped = skipped
        self.unknown = unknown
    }

    public var description: String {
        "TVHomeParse(loggedIn: \(loggedIn.map(String.init) ?? "unknown"), videos: \(videos.count), shorts: \(shorts), "
            + "handles: \(handles.count), continuation: \(sectionContinuation == nil ? "no" : "yes"))"
    }

    public var debugDescription: String { description }
}

/// A tolerant walker over YouTube's TV Home replies that keeps only real video tiles. Ported from the probe's `tvprobe/home.py`.
public enum TVHomeParser {
    public static func parse(_ reply: JSON) -> TVHomeParse {
        var walker = Walker()
        walker.walk(reply)
        return walker.result
    }
}

private struct Walker {
    /// Never videos; counted and never walked into (an ad's inner tile looks real).
    static let notVideos: Set<String> = [
        "adSlotRenderer", "promoShelfRenderer", "gridButtonRenderer", "searchBarRenderer", "feedNudgeRenderer",
    ]
    static let sectionLists: Set<String> = ["sectionListRenderer", "sectionListContinuation"]
    static let itemLists: [String: String] = [
        "horizontalListRenderer": "items", "horizontalListContinuation": "items",
        "gridRenderer": "items", "verticalListRenderer": "items",
    ]

    var result = TVHomeParse()
    private var shortDepth = 0

    // MARK: Descent over the wrappers above the lists

    mutating func walk(_ node: JSON) {
        if let list = node.array {
            for item in list { walk(item) }
        } else if let object = node.object {
            for key in object.keys.sorted() {
                visit(key, object[key] ?? .null, inList: false)
            }
        }
    }

    private mutating func visit(_ key: String, _ value: JSON, inList: Bool) {
        if Self.notVideos.contains(key) {
            result.skipped[key, default: 0] += 1
        } else if key == "shelfRenderer" {
            shelf(value)
        } else if key == "tileRenderer" {
            tile(value)
        } else if key == "lockupViewModel" {
            lockup(value)
        } else if Self.sectionLists.contains(key) {
            sectionList(value)
        } else if let itemsKey = Self.itemLists[key] {
            walkItems(value[itemsKey])
        } else if key == "responseContext" {
            responseContext(value)
        } else if inList {
            result.unknown[key, default: 0] += 1
        } else {
            walk(value)
        }
    }

    private mutating func responseContext(_ context: JSON) {
        for service in context["serviceTrackingParams"]?.array ?? [] where service["service"]?.string == "GFEEDBACK" {
            for param in service["params"]?.array ?? [] where param["key"]?.string == "logged_in" {
                let value = param["value"]?.string ?? param["value"]?.int.map(String.init)
                if value == "1" { result.loggedIn = true } else if value == "0" { result.loggedIn = false }
            }
        }
    }

    private mutating func sectionList(_ node: JSON) {
        guard node.object != nil else { return }
        if let token = node["continuations"]?[0]?["nextContinuationData"]?["continuation"]?.string,
           result.sectionContinuation == nil {
            result.sectionContinuation = token
        }
        walkItems(node["contents"])
    }

    private mutating func walkItems(_ items: JSON?) {
        guard let list = items?.array else { return }
        for item in list {
            guard let object = item.object else { continue }
            for key in object.keys.sorted() {
                visit(key, object[key] ?? .null, inList: true)
            }
        }
    }

    private mutating func shelf(_ shelf: JSON) {
        guard shelf.object != nil else { return }
        let kind = shelf["tvhtml5ShelfRendererType"]?.string ?? ""
        if let hide = shelf["tvhtml5Metadata"]?["hideLogo"], Self.truthy(hide) {
            result.skipped["upsellShelf", default: 0] += 1
            return
        }
        if kind.contains("EDU") {
            result.skipped["shelf:EDU", default: 0] += 1
            return
        }
        let shorts = kind.contains("SHORTS")
        if shorts { shortDepth += 1 }
        if let content = shelf["content"] { walk(content) }
        if shorts { shortDepth -= 1 }
    }

    // MARK: Tiles

    private mutating func tile(_ tile: JSON) {
        guard tile.object != nil else { return }
        let contentType = tile["contentType"]?.string ?? ""
        let style = tile["style"]?.string ?? ""
        let select = tile["onSelectCommand"]
        let reel = select?["reelWatchEndpoint"] != nil
        let videoID = Self.firstString(
            select?["watchEndpoint"]?["videoId"]?.string,
            select?["reelWatchEndpoint"]?["videoId"]?.string,
            tile["contentId"]?.string)
        let shortType = contentType.contains("SHORT") || contentType.contains("REEL") || style.contains("SHORT") || reel
        if !contentType.isEmpty, contentType != "TILE_CONTENT_TYPE_VIDEO", !shortType {
            result.skipped["tile:" + contentType.replacingOccurrences(of: "TILE_CONTENT_TYPE_", with: ""), default: 0] += 1
            return
        }
        guard let videoID else {
            result.unknown["tileRenderer", default: 0] += 1
            return
        }

        let header = tile["header"]?["tileHeaderRenderer"]
        let overlays = Self.nonEmpty(header?["thumbnailOverlays"]?.array) ?? tile["thumbnailOverlays"]?.array ?? []
        var durationText: String?
        var overlayStyle = ""
        for overlay in overlays {
            if let status = overlay["thumbnailOverlayTimeStatusRenderer"], status.object != nil {
                overlayStyle = (status["style"]?.string ?? "").uppercased()
                durationText = InnerTubeText.text(status["text"])
            }
        }
        let live = overlayStyle == "LIVE"
        let upcoming = overlayStyle == "UPCOMING"
        if live || upcoming { durationText = nil }
        let isShort = shortType || overlayStyle == "SHORTS" || shortDepth > 0 || (durationText == nil && !live && !upcoming)

        if isShort {
            result.shorts += 1
            return
        }

        var flags = Flags()
        flags.scan(tile["metadata"])
        flags.scan(tile["header"])
        if flags.paid {
            result.skipped["paid", default: 0] += 1
            return
        }

        let metadata = tile["metadata"]?["tileMetadataRenderer"]
        let lines = metadata?["lines"]?.array ?? []
        func lineItems(_ index: Int) -> [JSON] { lines[safe: index]?["lineRenderer"]?["items"]?.array ?? [] }
        func itemText(_ items: [JSON], _ index: Int) -> String? {
            InnerTubeText.text(items[safe: index]?["lineItemRenderer"]?["text"])
        }
        let channelName = itemText(lineItems(0), 0)
        var channel: ChannelRef?
        if let channelName {
            let browseID = metadata?.findAll("browseId").compactMap(\.string).first { $0.hasPrefix("UC") }
            channel = ChannelRef(id: browseID ?? "", name: channelName)
        }
        let viewText = itemText(lineItems(1), 0)

        result.videos.append(VideoSummary(
            id: videoID,
            title: InnerTubeText.text(metadata?["title"]) ?? "",
            channel: channel,
            thumbnails: InnerTubeText.thumbnails(header?["thumbnail"]),
            durationSeconds: InnerTubeText.parseDuration(durationText),
            viewCount: InnerTubeText.parseCount(viewText),
            viewCountText: viewText,
            publishedText: itemText(lineItems(1), 1),
            isLive: live,
            isUpcoming: upcoming,
            isShort: false,
            isMembersOnly: flags.members))

        let panel = tile["onLongPressCommand"]?["showEngagementPanelEndpoint"]
        if let tag = panel?["identifier"]?["tag"]?.string, let params = panel?["globalConfiguration"]?["params"]?.string,
           !tag.isEmpty, !params.isEmpty {
            result.handles[videoID] = TVCardHandle(panelID: tag, params: params)
        }
    }

    private mutating func lockup(_ node: JSON) {
        guard node.object != nil else { return }
        let contentType = node["contentType"]?.string ?? ""
        guard let videoID = node["contentId"]?.string, !videoID.isEmpty else {
            result.unknown["lockupViewModel", default: 0] += 1
            return
        }
        let isShort = contentType.contains("SHORT")
        if !contentType.isEmpty, !isShort, contentType != "LOCKUP_CONTENT_TYPE_VIDEO" {
            result.skipped["lockup:" + contentType.replacingOccurrences(of: "LOCKUP_CONTENT_TYPE_", with: ""), default: 0] += 1
            return
        }
        if isShort || shortDepth > 0 {
            result.shorts += 1
            return
        }
        var flags = Flags()
        flags.scan(node["metadata"])
        if flags.paid {
            result.skipped["paid", default: 0] += 1
            return
        }
        let title = InnerTubeText.text(node["metadata"]?["lockupMetadataViewModel"]?["title"]) ?? ""
        result.videos.append(VideoSummary(
            id: videoID,
            title: title,
            thumbnails: InnerTubeText.thumbnails(node["contentImage"]?.first("image") ?? node["contentImage"]),
            isMembersOnly: flags.members))
    }

    // MARK: Helpers

    private static func firstString(_ values: String?...) -> String? {
        values.first { ($0 ?? "").isEmpty == false } ?? nil
    }

    /// Python truthiness, as the probe reads `hideLogo`: false, null, 0, "", {} and [] are not set.
    private static func truthy(_ value: JSON) -> Bool {
        switch value {
        case .null: false
        case .bool(let flag): flag
        case .number(let number): number != 0
        case .string(let text): !text.isEmpty
        case .array(let list): !list.isEmpty
        case .object(let map): !map.isEmpty
        }
    }

    private static func nonEmpty(_ list: [JSON]?) -> [JSON]? {
        guard let list, !list.isEmpty else { return nil }
        return list
    }
}

/// Markers collected from style and icon values and key names anywhere inside a tile.
private struct Flags {
    var members = false
    var paid = false

    mutating func scan(_ node: JSON?) {
        guard let node else { return }
        if let object = node.object {
            for (key, value) in object {
                if key.lowercased().contains("ypc") { paid = true }
                if ["style", "iconType", "icon", "type"].contains(key), let text = value.string {
                    let upper = text.uppercased()
                    if upper.contains("MEMBERS") || upper.contains("SPONSORS_ONLY") { members = true }
                    if upper.contains("YPC") { paid = true }
                }
                scan(value)
            }
        } else if let list = node.array {
            for item in list { scan(item) }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
