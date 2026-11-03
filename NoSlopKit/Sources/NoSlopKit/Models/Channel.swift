import Foundation

/// A channel as shown in search results and lists.
public struct ChannelSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var handle: String?
    public var avatarURL: URL?
    public var subscriberCountText: String?
    public var videoCountText: String?
    public var descriptionSnippet: String?

    public init(
        id: String,
        name: String,
        handle: String? = nil,
        avatarURL: URL? = nil,
        subscriberCountText: String? = nil,
        videoCountText: String? = nil,
        descriptionSnippet: String? = nil
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.avatarURL = avatarURL
        self.subscriberCountText = subscriberCountText
        self.videoCountText = videoCountText
        self.descriptionSnippet = descriptionSnippet
    }

    public var ref: ChannelRef {
        ChannelRef(id: id, name: name, avatarURL: avatarURL, handle: handle)
    }
}

public enum ChannelTabKind: String, Codable, CaseIterable, Sendable {
    case videos, live, playlists
}

/// The header of a channel page.
public struct ChannelHeader: Hashable, Sendable {
    public var id: String
    public var name: String
    public var handle: String?
    public var avatarURL: URL?
    public var bannerURL: URL?
    public var subscriberCountText: String?
    public var videoCountText: String?
    public var description: String?

    public init(
        id: String,
        name: String,
        handle: String? = nil,
        avatarURL: URL? = nil,
        bannerURL: URL? = nil,
        subscriberCountText: String? = nil,
        videoCountText: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.avatarURL = avatarURL
        self.bannerURL = bannerURL
        self.subscriberCountText = subscriberCountText
        self.videoCountText = videoCountText
        self.description = description
    }

    public var ref: ChannelRef {
        ChannelRef(id: id, name: name, avatarURL: avatarURL, handle: handle)
    }
}

public struct ChannelPage: Sendable {
    public var header: ChannelHeader
    public var availableTabs: [ChannelTabKind]
    public var videos: Page<SearchItem>

    public init(header: ChannelHeader, availableTabs: [ChannelTabKind] = [], videos: Page<SearchItem> = Page()) {
        self.header = header
        self.availableTabs = availableTabs
        self.videos = videos
    }
}
