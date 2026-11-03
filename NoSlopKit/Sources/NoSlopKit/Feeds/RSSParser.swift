import Foundation

/// Parses a channel's `feeds/videos.xml` Atom feed into video summaries (Shorts flagged `isShort`).
///
/// Per `<entry>`: `yt:videoId`, `title`, `link rel="alternate"` (a `/shorts/` link marks a Short), `yt:channelId`,
/// `author/name`, `published`, `media:group/media:thumbnail` and `media:group/media:community/media:statistics`.
/// The feed has no durations. Entries without a video id are skipped. Damaged XML yields the entries that were
/// complete before the damage, never an error.
public enum RSSParser {
    /// A feed holds the latest 15; this is a guard against a runaway document.
    private static let maxEntries = 200

    public static func parse(_ data: Data) -> [VideoSummary] {
        guard !data.isEmpty else { return [] }
        let collector = EntryCollector(maxEntries: maxEntries)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false      // names stay "yt:videoId" / "media:title", which keeps them apart from "title"
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        parser.parse()
        return collector.videos
    }
}

/// Builds the videos while `XMLParser` walks the document. Single use, never shared between threads.
private final class EntryCollector: NSObject, XMLParserDelegate {
    private struct Entry {
        var videoID = ""
        var channelID: String?
        var title = ""
        var link: String?
        var authorName: String?
        var authorURI: String?
        var published: String?
        var thumbnail: Thumbnail?
        var views: Int?
    }

    private(set) var videos: [VideoSummary] = []

    private let maxEntries: Int
    private var path: [String] = []
    private var text = ""
    private var entry: Entry?
    /// Where the current entry sits in `path`, so element paths can be taken relative to it.
    private var entryDepth = 0

    private let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plainDates = ISO8601DateFormatter()

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        path.append(elementName)
        text = ""

        if entry == nil {
            if elementName == "entry" {
                entry = Entry()
                entryDepth = path.count
            }
            return
        }

        switch relativePath {
        case "link":
            let relation = attributeDict["rel"] ?? "alternate"
            if relation == "alternate", entry?.link == nil {
                entry?.link = attributeDict["href"]
            }
        case "media:group/media:thumbnail":
            if entry?.thumbnail == nil, let address = attributeDict["url"], let url = URL(string: address) {
                entry?.thumbnail = Thumbnail(url: url, width: attributeDict["width"].flatMap { Int($0) }, height: attributeDict["height"].flatMap { Int($0) })
            }
        case "media:group/media:community/media:statistics":
            entry?.views = attributeDict["views"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if entry != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if entry != nil { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            if !path.isEmpty { path.removeLast() }
        }
        guard entry != nil else { return }

        if elementName == "entry", path.count == entryDepth {
            finishEntry()
            if videos.count >= maxEntries { parser.abortParsing() }
            return
        }

        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch relativePath {
        case "yt:videoId": entry?.videoID = value
        case "yt:channelId": entry?.channelID = value
        case "title": entry?.title = value
        case "author/name": entry?.authorName = value
        case "author/uri": entry?.authorURI = value
        case "published": entry?.published = value
        default: break
        }
    }

    // MARK: Building

    /// The element path below the current `<entry>`, e.g. "author/name".
    private var relativePath: String {
        path.dropFirst(entryDepth).joined(separator: "/")
    }

    private func finishEntry() {
        defer { entry = nil }
        guard let entry, !entry.videoID.isEmpty else { return }

        videos.append(VideoSummary(
            id: entry.videoID,
            title: entry.title,
            channel: channel(of: entry),
            thumbnails: entry.thumbnail.map { [$0] } ?? [],
            viewCount: entry.views,
            publishedAt: entry.published.flatMap(date(from:)),
            isShort: entry.link?.contains("/shorts/") == true
        ))
    }

    /// The channel id is the entry's own `yt:channelId` (the feed header's lacks the "UC" prefix); the author URI
    /// ".../channel/UC…" is the fallback.
    private func channel(of entry: Entry) -> ChannelRef? {
        var id = entry.channelID.flatMap { $0.isEmpty ? nil : $0 }
        if id == nil, let uri = entry.authorURI, let last = URL(string: uri)?.lastPathComponent, last.hasPrefix("UC") {
            id = last
        }
        guard var id else { return nil }
        if !id.hasPrefix("UC"), id.count == 22 {
            id = "UC" + id
        }
        return ChannelRef(id: id, name: entry.authorName ?? "")
    }

    private func date(from text: String) -> Date? {
        fractionalDates.date(from: text) ?? plainDates.date(from: text)
    }
}
