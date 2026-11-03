import Foundation

/// A tappable span inside an `AttributedDescription`.
public struct DescriptionLink: Codable, Hashable, Sendable {
    public enum Target: Codable, Hashable, Sendable {
        case url(URL)
        case timestamp(seconds: Int)
        case video(id: String, startSeconds: Int?)
        case channel(id: String)
        case playlist(id: String)
        case hashtag(String)
    }

    /// UTF-16 offsets into `AttributedDescription.text`.
    public var range: Range<Int>
    public var target: Target

    public init(range: Range<Int>, target: Target) {
        self.range = range
        self.target = target
    }
}

/// Plain description text plus the links inside it.
public struct AttributedDescription: Codable, Hashable, Sendable {
    public var text: String
    public var links: [DescriptionLink]

    public init(text: String = "", links: [DescriptionLink] = []) {
        self.text = text
        self.links = links
    }

    public static let empty = AttributedDescription()
}

public struct Chapter: Codable, Hashable, Sendable {
    public var title: String
    public var startSeconds: Double
    public var thumbnailURL: URL?

    public init(title: String, startSeconds: Double, thumbnailURL: URL? = nil) {
        self.title = title
        self.startSeconds = startSeconds
        self.thumbnailURL = thumbnailURL
    }
}

/// Everything the watch page shows below the player.
public struct VideoDetails: Hashable, Sendable {
    public var id: String
    public var title: String
    public var channel: ChannelRef
    public var subscriberCountText: String?
    public var viewCount: Int?
    public var viewCountText: String?
    public var shortViewCountText: String?
    public var dateText: String?
    public var relativeDateText: String?
    public var likeCount: Int?
    public var likeCountText: String?
    public var description: AttributedDescription
    public var chapters: [Chapter]
    public var commentCountText: String?
    public var commentsContinuation: String?
    public var related: [VideoSummary]
    public var relatedContinuation: String?
    public var isLive: Bool

    public init(
        id: String,
        title: String,
        channel: ChannelRef,
        subscriberCountText: String? = nil,
        viewCount: Int? = nil,
        viewCountText: String? = nil,
        shortViewCountText: String? = nil,
        dateText: String? = nil,
        relativeDateText: String? = nil,
        likeCount: Int? = nil,
        likeCountText: String? = nil,
        description: AttributedDescription = .empty,
        chapters: [Chapter] = [],
        commentCountText: String? = nil,
        commentsContinuation: String? = nil,
        related: [VideoSummary] = [],
        relatedContinuation: String? = nil,
        isLive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.subscriberCountText = subscriberCountText
        self.viewCount = viewCount
        self.viewCountText = viewCountText
        self.shortViewCountText = shortViewCountText
        self.dateText = dateText
        self.relativeDateText = relativeDateText
        self.likeCount = likeCount
        self.likeCountText = likeCountText
        self.description = description
        self.chapters = chapters
        self.commentCountText = commentCountText
        self.commentsContinuation = commentsContinuation
        self.related = related
        self.relatedContinuation = relatedContinuation
        self.isLive = isLive
    }

    /// A list-style summary of this video (id, title, channel, views, relative date, live flag).
    public var summary: VideoSummary {
        VideoSummary(
            id: id,
            title: title,
            channel: channel,
            viewCount: viewCount,
            viewCountText: viewCountText,
            publishedText: relativeDateText,
            isLive: isLive
        )
    }
}
