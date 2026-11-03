import Foundation

/// One image rendition. `width`/`height` are nil when YouTube does not say.
public struct Thumbnail: Codable, Hashable, Sendable {
    public var url: URL
    public var width: Int?
    public var height: Int?

    public init(url: URL, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }
}

extension Array where Element == Thumbnail {
    /// The smallest thumbnail whose width is at least `minWidth`; otherwise the widest one that has a
    /// width; otherwise the last element. Order of the array does not matter.
    public func best(minWidth: Int) -> Thumbnail? {
        var smallestEnough: Thumbnail?
        var widest: Thumbnail?
        for thumbnail in self {
            guard let width = thumbnail.width else { continue }
            if width >= minWidth, width < (smallestEnough?.width ?? Int.max) {
                smallestEnough = thumbnail
            }
            if width > (widest?.width ?? Int.min) {
                widest = thumbnail
            }
        }
        return smallestEnough ?? widest ?? last
    }
}

public struct ChannelRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var avatarURL: URL?
    public var handle: String?

    public init(id: String, name: String, avatarURL: URL? = nil, handle: String? = nil) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.handle = handle
    }
}

public struct VideoSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var channel: ChannelRef?
    /// Ascending width.
    public var thumbnails: [Thumbnail]
    public var durationSeconds: Int?
    public var viewCount: Int?
    public var viewCountText: String?
    public var publishedText: String?
    public var publishedAt: Date?
    public var isLive: Bool
    public var isUpcoming: Bool
    public var isShort: Bool
    public var isMembersOnly: Bool

    public init(
        id: String,
        title: String,
        channel: ChannelRef? = nil,
        thumbnails: [Thumbnail] = [],
        durationSeconds: Int? = nil,
        viewCount: Int? = nil,
        viewCountText: String? = nil,
        publishedText: String? = nil,
        publishedAt: Date? = nil,
        isLive: Bool = false,
        isUpcoming: Bool = false,
        isShort: Bool = false,
        isMembersOnly: Bool = false
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.thumbnails = thumbnails
        self.durationSeconds = durationSeconds
        self.viewCount = viewCount
        self.viewCountText = viewCountText
        self.publishedText = publishedText
        self.publishedAt = publishedAt
        self.isLive = isLive
        self.isUpcoming = isUpcoming
        self.isShort = isShort
        self.isMembersOnly = isMembersOnly
    }

    /// Persisted JSON may come from an older build: every key except `id` decodes to a default when missing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.channel = try c.decodeIfPresent(ChannelRef.self, forKey: .channel)
        self.thumbnails = try c.decodeIfPresent([Thumbnail].self, forKey: .thumbnails) ?? []
        self.durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds)
        self.viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
        self.viewCountText = try c.decodeIfPresent(String.self, forKey: .viewCountText)
        self.publishedText = try c.decodeIfPresent(String.self, forKey: .publishedText)
        self.publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        self.isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        self.isUpcoming = try c.decodeIfPresent(Bool.self, forKey: .isUpcoming) ?? false
        self.isShort = try c.decodeIfPresent(Bool.self, forKey: .isShort) ?? false
        self.isMembersOnly = try c.decodeIfPresent(Bool.self, forKey: .isMembersOnly) ?? false
    }

    /// `https://www.youtube.com/watch?v=<id>`
    public var watchURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: id)]
        // Scheme, host, path and a percent-encoded query always form a valid URL; the fallback is unreachable.
        return components.url ?? URL(string: "https://www.youtube.com/")!
    }

    /// `thumbnails`, or `defaultThumbnails(for: id)` when YouTube gave none.
    public var displayThumbnails: [Thumbnail] {
        thumbnails.isEmpty ? Self.defaultThumbnails(for: id) : thumbnails
    }

    /// Always-available ytimg renditions: mqdefault 320x180, hqdefault 480x360, sddefault 640x480.
    public static func defaultThumbnails(for id: String) -> [Thumbnail] {
        let renditions: [(name: String, width: Int, height: Int)] = [
            ("mqdefault", 320, 180),
            ("hqdefault", 480, 360),
            ("sddefault", 640, 480),
        ]
        return renditions.compactMap { rendition in
            URL(string: "https://i.ytimg.com/vi/\(id)/\(rendition.name).jpg")
                .map { Thumbnail(url: $0, width: rendition.width, height: rendition.height) }
        }
    }
}
