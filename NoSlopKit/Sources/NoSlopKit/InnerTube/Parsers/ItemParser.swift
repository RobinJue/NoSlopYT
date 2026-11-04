import Foundation

/// Maps individual InnerTube renderers (`videoRenderer`, `lockupViewModel`, ...) to models, dropping ads and AI blocks.
///
/// Nothing in here throws or traps on odd data: a renderer that lacks what an item needs (an id, a title) is skipped,
/// and every optional detail is simply left out when it can't be read. The same walker (`harvest`) serves the search,
/// channel, playlist and related parsers.
public enum ItemParser {
    // MARK: Public API

    /// Harvests every video, channel and playlist under `json` in document order, dropping ads and AI summaries.
    /// Arrays are walked in order and object keys in sorted order (a JSON object has no order of its own), so the
    /// result is deterministic. Shorts are included, flagged with `isShort`.
    public static func items(in json: JSON) -> [SearchItem] {
        harvest(json).items
    }

    /// `videoRenderer`, and the renderers that share its fields (`compactVideoRenderer`, `gridVideoRenderer`,
    /// `playlistVideoRenderer`, `reelItemRenderer`). `json` is the renderer itself, the value under that key.
    public static func video(fromVideoRenderer json: JSON) -> VideoSummary? {
        guard let id = clean(json["videoId"]?.string) else { return nil }
        // Private and deleted entries of a playlist keep their id and get a "[Private video]" title.
        guard json["isPlayable"]?.bool != false else { return nil }
        guard let title = clean(InnerTubeText.text(json["title"]) ?? InnerTubeText.text(json["headline"])) else { return nil }

        let overlayStyles = (json["thumbnailOverlays"]?.array ?? []).compactMap {
            $0["thumbnailOverlayTimeStatusRenderer"]?["style"]?.string
        }
        let badgeStyles = (json["badges"]?.array ?? []).compactMap { $0["metadataBadgeRenderer"]?["style"]?.string }

        let isLive = badgeStyles.contains("BADGE_STYLE_TYPE_LIVE_NOW") || overlayStyles.contains("LIVE")
        let isUpcoming = json["upcomingEventData"] != nil || overlayStyles.contains("UPCOMING")
        let isMembersOnly = badgeStyles.contains("BADGE_STYLE_TYPE_MEMBERS_ONLY")
        let isShort = json["navigationEndpoint"]?["reelWatchEndpoint"] != nil
            || overlayStyles.contains("SHORTS")
            || isShortsLink(json["navigationEndpoint"])

        var viewsText = clean(InnerTubeText.text(json["viewCountText"]))
        var publishedText = clean(InnerTubeText.text(json["publishedTimeText"]))
        // Playlist entries put both into one "296K views • 2 years ago" line.
        if viewsText == nil || publishedText == nil, let info = clean(InnerTubeText.text(json["videoInfo"])) {
            let found = details(from: info.split(whereSeparator: { $0 == "•" || $0 == "·" }).compactMap {
                clean(String($0)).map { MetadataPart(text: $0) }
            })
            viewsText = viewsText ?? found.viewsText
            publishedText = publishedText ?? found.publishedText
        }
        viewsText = viewsText ?? clean(InnerTubeText.text(json["shortViewCountText"]))

        var publishedAt: Date?
        if let upcoming = json["upcomingEventData"] {
            publishedAt = upcoming["startTime"]?.double.map { Date(timeIntervalSince1970: $0) }
            publishedText = publishedText ?? clean(InnerTubeText.text(upcoming["upcomingEventText"]))
        }

        let duration = InnerTubeText.parseDuration(InnerTubeText.text(json["lengthText"]))
            ?? json["lengthSeconds"]?.int
            ?? overlayDuration(in: json["thumbnailOverlays"])

        return VideoSummary(
            id: id,
            title: title,
            channel: channel(inVideoRenderer: json),
            thumbnails: InnerTubeText.thumbnails(json["thumbnail"]),
            durationSeconds: duration,
            viewCount: isLive || isUpcoming ? nil : viewCount(from: viewsText),
            viewCountText: viewsText,
            publishedText: publishedText,
            publishedAt: publishedAt,
            isLive: isLive,
            isUpcoming: isUpcoming,
            isShort: isShort,
            isMembersOnly: isMembersOnly
        )
    }

    /// A `lockupViewModel` with `LOCKUP_CONTENT_TYPE_VIDEO`: the format of channel tabs, playlists and "up next".
    public static func video(fromLockup json: JSON) -> VideoSummary? {
        guard lockupKind(of: json) == .video, let id = clean(json["contentId"]?.string) else { return nil }
        let metadata = json["metadata"]?["lockupMetadataViewModel"]
        guard let title = clean(InnerTubeText.text(metadata?["title"])) else { return nil }

        // Overlay badges: the duration, and the markers for live, upcoming and members-only videos.
        var duration: Int?
        var isLive = false
        var isUpcoming = false
        var isMembersOnly = false
        for badge in json["contentImage"]?.findAll("thumbnailBadgeViewModel") ?? [] {
            let text = clean(InnerTubeText.text(badge["text"]))
            let style = badge["badgeStyle"]?.string?.uppercased() ?? ""
            duration = duration ?? InnerTubeText.parseDuration(text)
            let label = text?.uppercased() ?? ""
            if label == "LIVE" || style.hasSuffix("_LIVE") { isLive = true }
            if label == "UPCOMING" || label == "PREMIERE" || style.hasSuffix("_UPCOMING") { isUpcoming = true }
            if isMembersOnlyMark(label: label, style: style) { isMembersOnly = true }
        }
        // The members-only mark of a video in a list is not over the thumbnail but a status chip under the title.
        isMembersOnly = isMembersOnly || statusChips(of: metadata).contains {
            isMembersOnlyMark(
                label: clean(InnerTubeText.text($0["badgeText"]))?.uppercased() ?? "",
                style: $0["badgeStyle"]?.string?.uppercased() ?? ""
            )
        }

        // Metadata rows: [channel] then [views, age]; a channel tab has only the second kind of row. The first row
        // is the channel's when the rows after it hold the statistics, or when it holds none itself.
        let rows = metadataRows(of: metadata).filter { !$0.isEmpty }
        var channelPart: MetadataPart?
        var statisticParts = rows.flatMap { $0 }
        if rows.count >= 2 {
            let later = rows.dropFirst().flatMap { $0 }
            if later.contains(where: { kind(of: $0) != .other }) || !rows[0].contains(where: { kind(of: $0) != .other }) {
                channelPart = rows[0].first
                statisticParts = later
            }
        }
        let found = details(from: statisticParts)
        isLive = isLive || found.isLive
        isUpcoming = isUpcoming || found.isUpcoming

        return VideoSummary(
            id: id,
            title: title,
            channel: channel(inLockup: metadata, namePart: channelPart),
            thumbnails: InnerTubeText.thumbnails(json["contentImage"]?["thumbnailViewModel"]?["image"]),
            durationSeconds: isLive ? nil : duration,
            viewCount: isLive || isUpcoming ? nil : viewCount(from: found.viewsText),
            viewCountText: found.viewsText,
            publishedText: found.publishedText,
            publishedAt: nil,
            isLive: isLive,
            isUpcoming: isUpcoming,
            isShort: json.first("reelWatchEndpoint") != nil,
            isMembersOnly: isMembersOnly
        )
    }

    /// A `lockupViewModel` with `LOCKUP_CONTENT_TYPE_PLAYLIST`, `_PODCAST` or `_COURSE`.
    public static func playlist(fromLockup json: JSON) -> PlaylistSummary? {
        guard lockupKind(of: json) == .playlist, let id = clean(json["contentId"]?.string), !isMix(id) else { return nil }
        let metadata = json["metadata"]?["lockupMetadataViewModel"]
        guard let title = clean(InnerTubeText.text(metadata?["title"])) else { return nil }

        let artwork = json["contentImage"]?["collectionThumbnailViewModel"]?["primaryThumbnail"]?["thumbnailViewModel"]
            ?? json["contentImage"]?["thumbnailViewModel"]
        // The count sits in a badge over the artwork: "14 videos", "8 lessons", "8 episodes".
        let countText = (artwork?.findAll("thumbnailBadgeViewModel") ?? [])
            .compactMap { clean(InnerTubeText.text($0["text"])) }
            .first { $0.contains(where: \.isNumber) }

        // The first row reads "Blender Guru · Playlist": the channel, then the kind of list (which links to the
        // channel too). On a channel's own playlist tab only the kind is left, so a lone part is not a channel.
        var channel: ChannelRef?
        if let row = metadataRows(of: metadata).first(where: { !$0.isEmpty }), row.count >= 2,
           let part = row.first, let channelID = part.channelID {
            channel = ChannelRef(id: channelID, name: part.text, avatarURL: nil, handle: handle(fromPath: part.canonicalPath))
        }

        return PlaylistSummary(
            id: id,
            title: title,
            channel: channel,
            thumbnails: InnerTubeText.thumbnails(artwork?["image"]),
            videoCount: itemCount(from: countText),
            videoCountText: countText
        )
    }

    /// A `shortsLockupViewModel`, from a Shorts shelf or a channel's Shorts tab. Always `isShort`.
    public static func short(fromShortsLockup json: JSON) -> VideoSummary? {
        let tapped = json["onTap"]?["innertubeCommand"]?["reelWatchEndpoint"]?["videoId"]?.string
        let fromEntity = json["entityId"]?.string.flatMap { entity in
            entity.hasPrefix("shorts-shelf-item-") ? String(entity.dropFirst("shorts-shelf-item-".count)) : nil
        }
        guard let id = clean(tapped) ?? clean(fromEntity) ?? clean(json.first("reelWatchEndpoint")?["videoId"]?.string),
              let title = clean(InnerTubeText.text(json["overlayMetadata"]?["primaryText"]))
        else { return nil }

        let viewsText = clean(InnerTubeText.text(json["overlayMetadata"]?["secondaryText"]))
        let frames = json["thumbnailViewModel"]?["thumbnailViewModel"]?["image"]
            ?? json["thumbnailViewModel"]?["image"]
            ?? json["thumbnail"]
        return VideoSummary(
            id: id,
            title: title,
            thumbnails: InnerTubeText.thumbnails(frames),
            viewCount: viewCount(from: viewsText),
            viewCountText: viewsText,
            isShort: true
        )
    }

    /// `channelRenderer` and `gridChannelRenderer`.
    ///
    /// YouTube's quirk in search results: `subscriberCountText` holds the `@handle` and `videoCountText` holds the
    /// subscriber count (the real video count isn't given). Grid channels use the two fields as named.
    public static func channel(fromChannelRenderer json: JSON) -> ChannelSummary? {
        guard let id = clean(json["channelId"]?.string), let name = clean(InnerTubeText.text(json["title"])) else { return nil }
        let first = clean(InnerTubeText.text(json["subscriberCountText"]))
        let second = clean(InnerTubeText.text(json["videoCountText"]))

        var handle: String?
        var subscribers = first
        var videos = second
        if let first, first.hasPrefix("@") {
            handle = first
            subscribers = second
            videos = nil
        }
        handle = handle ?? Self.handle(fromPath: json["navigationEndpoint"]?["browseEndpoint"]?["canonicalBaseUrl"]?.string)

        return ChannelSummary(
            id: id,
            name: name,
            handle: handle,
            avatarURL: InnerTubeText.thumbnails(json["thumbnail"]).last?.url,
            subscriberCountText: subscribers,
            videoCountText: videos,
            descriptionSnippet: clean(InnerTubeText.text(json["descriptionSnippet"]))
        )
    }

    // MARK: Harvesting

    /// What a walk over part of a response found.
    struct Harvest {
        var items: [SearchItem] = []
        /// The last continuation token met outside ads and side panels, nil when there is none.
        var continuation: String?
    }

    /// Walks `json` and collects every item renderer it contains, in order, together with the last continuation
    /// token. It maps and stops at item renderers (their menus and metadata hold no further results) and never
    /// enters ads, AI summaries, refinement cards, sign-in nudges or engagement panels.
    ///
    /// The walk uses an explicit stack instead of recursion: how deeply a response nests must never decide whether
    /// the app survives it (a debug build spends kilobytes of stack per level, and a worker thread has 512 KB).
    static func harvest(_ json: JSON) -> Harvest {
        enum Step {
            case visit(JSON)
            case collect(key: String, JSON)
        }

        var result = Harvest()
        var pending: [Step] = [.visit(json)]
        while let step = pending.popLast() {
            switch step {
            case .collect(let key, let renderer):
                collect(key, renderer, into: &result)
            case .visit(let node):
                switch node {
                case .array(let values):
                    // Pushed in reverse so that they come off the stack in order.
                    for value in values.reversed() {
                        pending.append(.visit(value))
                    }
                case .object(let object):
                    for key in object.keys.sorted().reversed() {
                        guard let child = object[key], !isSkipped(key) else { continue }
                        pending.append(collectedKeys.contains(key) ? .collect(key: key, child) : .visit(child))
                    }
                case .string, .number, .bool, .null:
                    break
                }
            }
        }
        return result
    }

    private static let collectedKeys: Set<String> = [
        "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer", "reelItemRenderer",
        "shortsLockupViewModel", "lockupViewModel", "channelRenderer", "gridChannelRenderer",
        "playlistRenderer", "gridPlaylistRenderer", "compactPlaylistRenderer",
        "continuationItemRenderer", "continuationItemViewModel",
    ]

    /// Maps one item renderer (or reads one continuation item) into `result`.
    private static func collect(_ key: String, _ renderer: JSON, into result: inout Harvest) {
        switch key {
        case "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer":
            if let video = video(fromVideoRenderer: renderer) { result.items.append(.video(video)) }
        case "reelItemRenderer":
            if var video = video(fromVideoRenderer: renderer) {
                video.isShort = true
                result.items.append(.video(video))
            }
        case "shortsLockupViewModel":
            if let short = short(fromShortsLockup: renderer) { result.items.append(.video(short)) }
        case "lockupViewModel":
            switch lockupKind(of: renderer) {
            case .video?:
                if let video = video(fromLockup: renderer) { result.items.append(.video(video)) }
            case .playlist?:
                if let playlist = playlist(fromLockup: renderer) { result.items.append(.playlist(playlist)) }
            case nil:
                break
            }
        case "channelRenderer", "gridChannelRenderer":
            if let channel = channel(fromChannelRenderer: renderer) { result.items.append(.channel(channel)) }
        case "playlistRenderer", "gridPlaylistRenderer", "compactPlaylistRenderer":
            if let playlist = playlist(fromPlaylistRenderer: renderer) { result.items.append(.playlist(playlist)) }
        case "continuationItemRenderer", "continuationItemViewModel":
            if let token = continuationToken(in: renderer) { result.continuation = token }
        default:
            break
        }
    }

    /// The token of a `continuationItemRenderer` (`continuationEndpoint.continuationCommand.token`) or a
    /// `continuationItemViewModel` (`continuationCommand.innertubeCommand.continuationCommand.token`).
    static func continuationToken(in item: JSON) -> String? {
        for command in item.findAll("continuationCommand") {
            if let token = command["token"]?.string, !token.isEmpty { return token }
        }
        return nil
    }

    /// The item arrays of a continuation response: `appendContinuationItemsAction.continuationItems` inside
    /// `onResponseReceivedActions` (browse), `onResponseReceivedEndpoints` (next) or `onResponseReceivedCommands`
    /// (search). Nil when the response has none, which includes first pages (their commands are something else).
    static func continuationItems(in json: JSON) -> JSON? {
        var batches: [JSON] = []
        for key in ["onResponseReceivedActions", "onResponseReceivedEndpoints", "onResponseReceivedCommands"] {
            for action in json[key]?.array ?? [] {
                if let items = action["appendContinuationItemsAction"]?["continuationItems"], items.array != nil {
                    batches.append(items)
                }
            }
        }
        return batches.isEmpty ? nil : .array(batches)
    }

    // MARK: What is never a result

    private static let skippedKeys: Set<String> = [
        // Ads.
        "adSlotRenderer", "inFeedAdLayoutRenderer", "promotedVideoRenderer", "promotedSparklesWebRenderer", "searchPyvRenderer",
        "promotedSparklesTextSearchRenderer", "compactPromotedVideoRenderer", "displayAdRenderer", "bannerPromoRenderer",
        // AI summaries.
        "videoSummaryContentViewModel", "genAiFeedbackFormViewModel",
        // Not results: search refinement cards, the sign-in nudge on the anonymous home, side panels (a channel's
        // "about" panel carries a continuation of its own).
        "horizontalCardListRenderer", "feedNudgeRenderer", "engagementPanelSectionListRenderer",
    ]

    private static func isSkipped(_ key: String) -> Bool {
        skippedKeys.contains(key) || key.hasPrefix("promoted") || key.hasPrefix("adSlot") || key.hasSuffix("AdRenderer")
    }

    // MARK: Lockups

    enum LockupKind { case video, playlist }

    /// By `contentType`; a lockup without one is recognised by its artwork (a stack of thumbnails is a playlist).
    static func lockupKind(of json: JSON) -> LockupKind? {
        if let type = json["contentType"]?.string {
            switch type {
            case "LOCKUP_CONTENT_TYPE_VIDEO": return .video
            case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_PODCAST", "LOCKUP_CONTENT_TYPE_COURSE": return .playlist
            default: return nil
            }
        }
        if json["contentImage"]?["collectionThumbnailViewModel"] != nil { return .playlist }
        if json["contentImage"]?["thumbnailViewModel"] != nil { return .video }
        return nil
    }

    /// "Mix" lists (ids starting with `RD`) are generated per viewer and have no playlist page to open.
    private static func isMix(_ playlistID: String) -> Bool {
        playlistID.hasPrefix("RD")
    }

    /// One piece of a metadata row: `text` plus the channel it links to, if it does.
    struct MetadataPart {
        var text: String
        var accessibilityLabel: String?
        var channelID: String?
        var canonicalPath: String?
    }

    private static func metadataRows(of metadata: JSON?) -> [[MetadataPart]] {
        guard let rows = metadata?["metadata"]?["contentMetadataViewModel"]?["metadataRows"]?.array else { return [] }
        return rows.map { row in
            (row["metadataParts"]?.array ?? []).compactMap { part -> MetadataPart? in
                guard let text = clean(InnerTubeText.text(part["text"])) else { return nil }
                let endpoint = part["text"]?.first("browseEndpoint")
                return MetadataPart(
                    text: text,
                    accessibilityLabel: clean(part["accessibilityLabel"]?.string),
                    channelID: channelID(endpoint?["browseId"]?.string),
                    canonicalPath: endpoint?["canonicalBaseUrl"]?.string
                )
            }
        }
    }

    /// The status chips of a lockup ("New", "CC", "Fundraiser", "Members only"): `badges[].badgeViewModel` in rows of
    /// their own among the metadata rows, next to the rows with `metadataParts`. They carry no views or age, which is
    /// why `metadataRows(of:)` (parts only) leaves them out and the statistics are read as before.
    private static func statusChips(of metadata: JSON?) -> [JSON] {
        let rows = metadata?["metadata"]?["contentMetadataViewModel"]?["metadataRows"]?.array ?? []
        return rows.flatMap { row in (row["badges"]?.array ?? []).compactMap { $0["badgeViewModel"] } }
    }

    /// Whether a badge (a chip, or one over the thumbnail) says that only members of the channel can watch the video.
    /// The style is what counts (`BADGE_MEMBERS_ONLY`, the same in every language); the text is translated, so the
    /// English "Members only" is only a fallback. Both are upper-cased by the caller.
    private static func isMembersOnlyMark(label: String, style: String) -> Bool {
        style.contains("MEMBERS") || label.contains("MEMBERS ONLY")
    }

    /// The channel of a video lockup: its name is the first part of the first row, its id and avatar are on the
    /// avatar next to the title (or, failing that, on the name's own link).
    private static func channel(inLockup metadata: JSON?, namePart: MetadataPart?) -> ChannelRef? {
        guard let name = namePart?.text else { return nil }
        let avatar = metadata?["image"]
        let endpoint = avatar?.first("browseEndpoint")
        guard let id = channelID(endpoint?["browseId"]?.string) ?? namePart?.channelID else { return nil }
        return ChannelRef(
            id: id,
            name: name,
            avatarURL: InnerTubeText.thumbnails(avatar?.first("avatarViewModel")?["image"]).last?.url,
            handle: handle(fromPath: endpoint?["canonicalBaseUrl"]?.string ?? namePart?.canonicalPath)
        )
    }

    // MARK: Views, ages and counts

    private enum PartKind { case views, published, other }

    private static let viewWords: Set<String> = ["view", "views", "watching", "waiting"]
    private static let dateWords: Set<String> = ["ago", "streamed", "premiered", "premieres", "premiere", "scheduled"]

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    private static func words(of part: MetadataPart) -> Set<String> {
        words(in: [part.text, part.accessibilityLabel].compactMap { $0 }.joined(separator: " "))
    }

    /// The tokens "9.8K views" or "13d ago" give away; "7.8M" alone counts as views too. English only: anything
    /// else is `.other` and is placed by position (see `details`).
    private static func kind(of part: MetadataPart) -> PartKind {
        let tokens = words(of: part)
        let hasView = !tokens.isDisjoint(with: viewWords)
        let hasDate = !tokens.isDisjoint(with: dateWords)
        if hasDate && !hasView { return .published }
        if hasView && !hasDate { return .views }
        if !hasView && !hasDate && isBareCount(part.text) { return .views }
        return .other
    }

    struct Details {
        var viewsText: String?
        var publishedText: String?
        var isLive = false
        var isUpcoming = false
    }

    /// Views and age out of the loose parts of a lockup's metadata ("23K views", "Streamed 5 days ago", "7.8M").
    /// "N watching" marks a live stream, "N waiting" and "Scheduled for …" an upcoming one. When no part can be
    /// recognised but there are exactly two (a language this parser has no words for), they are taken as
    /// "<views> · <age>", which is how YouTube orders them.
    static func details(from parts: [MetadataPart]) -> Details {
        var result = Details()
        var unrecognised: [MetadataPart] = []
        for part in parts {
            let tokens = words(of: part)
            switch kind(of: part) {
            case .published:
                result.publishedText = result.publishedText ?? part.text
                if !tokens.isDisjoint(with: ["premieres", "premiere", "scheduled"]) { result.isUpcoming = true }
            case .views:
                result.viewsText = result.viewsText ?? part.text
                if tokens.contains("watching") { result.isLive = true }
                if tokens.contains("waiting") { result.isUpcoming = true }
            case .other:
                unrecognised.append(part)
            }
        }
        if result.viewsText == nil, result.publishedText == nil, unrecognised.count == 2 {
            result.viewsText = unrecognised[0].text
            result.publishedText = unrecognised[1].text
        }
        return result
    }

    /// "7.8M", "5K", "1,234": digits with an optional K, M or B.
    private static func isBareCount(_ text: String) -> Bool {
        var characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if characters.count > 1, let last = characters.last, "KkMmBb".contains(last) {
            characters.removeLast()
            if characters.last == " " { characters.removeLast() }
        }
        guard let first = characters.first, first.isASCII, first.isNumber else { return false }
        return characters.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "," || $0 == "." }
    }

    /// A view count from YouTube's text. Only English texts ("9.8K views", "No views") and bare counts ("7.8M")
    /// are read. Any other language keeps YouTube's own text and gets no number: the screens word a known count in
    /// English ("2.8M views"), and the text YouTube sent is the better one on a screen in the user's language.
    /// (`parseCount` itself never misreads such texts; it answers nil for the units it does not know.)
    static func viewCount(from text: String?) -> Int? {
        guard let text else { return nil }
        let tokens = words(in: text)
        guard tokens.contains("view") || tokens.contains("views") || isBareCount(text) else { return nil }
        return InnerTubeText.parseCount(text)
    }

    /// A count of videos or lessons ("14 videos", "1,234 videos") when the text holds exactly one number.
    /// "1 234 vidéos" (grouped with spaces) holds two and is not read.
    static func itemCount(from text: String?) -> Int? {
        guard let text else { return nil }
        var runs = 0
        var inRun = false
        for character in text {
            let isDigit = character.isNumber
            if isDigit && !inRun { runs += 1 }
            inRun = isDigit || (inRun && (character == "," || character == "."))
        }
        return runs == 1 ? InnerTubeText.parseCount(text) : nil
    }

    // MARK: videoRenderer details

    /// The channel of a video renderer: its byline, with the avatar from whichever field carries one.
    private static func channel(inVideoRenderer json: JSON) -> ChannelRef? {
        let avatarNodes: [JSON?] = [
            json["channelThumbnailSupportedRenderers"]?["channelThumbnailWithLinkRenderer"]?["thumbnail"],
            json["channelThumbnail"],
            json["avatar"]?.first("avatarViewModel")?["image"],
        ]
        let avatarURL = avatarNodes.lazy.compactMap { InnerTubeText.thumbnails($0).last?.url }.first

        for key in ["ownerText", "longBylineText", "shortBylineText"] {
            for run in json[key]?["runs"]?.array ?? [] {
                let endpoint = run["navigationEndpoint"]?["browseEndpoint"]
                guard let name = clean(run["text"]?.string), let id = channelID(endpoint?["browseId"]?.string) else { continue }
                let path = endpoint?["canonicalBaseUrl"]?.string
                return ChannelRef(id: id, name: name, avatarURL: avatarURL, handle: handle(fromPath: path))
            }
        }
        return nil
    }

    /// The duration shown on the thumbnail, for renderers that have no `lengthText`.
    private static func overlayDuration(in overlays: JSON?) -> Int? {
        for overlay in overlays?.array ?? [] {
            if let text = overlay["thumbnailOverlayTimeStatusRenderer"]?["text"],
               let seconds = InnerTubeText.parseDuration(InnerTubeText.text(text)) {
                return seconds
            }
        }
        return nil
    }

    private static func isShortsLink(_ endpoint: JSON?) -> Bool {
        let metadata = endpoint?["commandMetadata"]?["webCommandMetadata"]
        return metadata?["webPageType"]?.string == "WEB_PAGE_TYPE_SHORTS"
            || metadata?["url"]?.string?.hasPrefix("/shorts/") == true
    }

    // MARK: Old playlist renderers

    /// `playlistRenderer`, `gridPlaylistRenderer`, `compactPlaylistRenderer`.
    private static func playlist(fromPlaylistRenderer json: JSON) -> PlaylistSummary? {
        guard let id = clean(json["playlistId"]?.string), !isMix(id),
              let title = clean(InnerTubeText.text(json["title"]))
        else { return nil }

        // `thumbnails` is a list of thumbnail sets (the first is the playlist's own); `thumbnail` is one set.
        let thumbnails = InnerTubeText.thumbnails(json["thumbnails"]?[0]).isEmpty
            ? InnerTubeText.thumbnails(json["thumbnail"])
            : InnerTubeText.thumbnails(json["thumbnails"]?[0])
        let countText = clean(InnerTubeText.text(json["videoCountText"])) ?? clean(json["videoCount"]?.string)
        let byline = json["longBylineText"] ?? json["shortBylineText"]
        var channel: ChannelRef?
        if let run = byline?["runs"]?[0], let name = clean(run["text"]?.string) {
            let endpoint = run["navigationEndpoint"]?["browseEndpoint"]
            if let ownerID = Self.channelID(endpoint?["browseId"]?.string) {
                let path = endpoint?["canonicalBaseUrl"]?.string
                channel = ChannelRef(id: ownerID, name: name, avatarURL: nil, handle: handle(fromPath: path))
            }
        }
        return PlaylistSummary(
            id: id, title: title, channel: channel, thumbnails: thumbnails,
            videoCount: itemCount(from: countText), videoCountText: countText
        )
    }

    // MARK: Small helpers

    /// Trimmed text; nil when nothing is left.
    static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A channel id: every one starts with "UC" (anything else, such as "VL…", is not a channel).
    static func channelID(_ id: String?) -> String? {
        guard let id = clean(id), id.hasPrefix("UC") else { return nil }
        return id
    }

    /// "@blenderguru" out of "/@blenderguru" or "http://www.youtube.com/@BlenderOfficial", percent-decoded.
    /// Vanity paths such as "/c/Name" or "/user/Name" are not handles.
    static func handle(fromPath path: String?) -> String? {
        guard let path, let range = path.range(of: "/@") else { return nil }
        var segment = path[path.index(after: range.lowerBound)...]
        if let end = segment.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            segment = segment[..<end]
        }
        let raw = String(segment)
        let handle = raw.removingPercentEncoding ?? raw
        return handle.count > 1 ? handle : nil
    }
}
