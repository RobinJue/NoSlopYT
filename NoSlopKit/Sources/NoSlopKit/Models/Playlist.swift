import Foundation

public struct PlaylistSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var channel: ChannelRef?
    public var thumbnails: [Thumbnail]
    public var videoCount: Int?
    public var videoCountText: String?

    public init(
        id: String,
        title: String,
        channel: ChannelRef? = nil,
        thumbnails: [Thumbnail] = [],
        videoCount: Int? = nil,
        videoCountText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.channel = channel
        self.thumbnails = thumbnails
        self.videoCount = videoCount
        self.videoCountText = videoCountText
    }
}

public struct PlaylistPage: Sendable {
    public var info: PlaylistSummary
    public var description: String?
    public var videos: Page<VideoSummary>

    public init(info: PlaylistSummary, description: String? = nil, videos: Page<VideoSummary> = Page()) {
        self.info = info
        self.description = description
        self.videos = videos
    }
}
