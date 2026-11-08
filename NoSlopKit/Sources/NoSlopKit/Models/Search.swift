import Foundation

/// One page of a paginated list. `continuation` is the opaque token for the next page, nil at the end.
public struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    public var continuation: String?

    public init(items: [Item] = [], continuation: String? = nil) {
        self.items = items
        self.continuation = continuation
    }
}

extension Page: Equatable where Item: Equatable {}

public enum SearchItem: Hashable, Sendable, Identifiable {
    case video(VideoSummary)
    case channel(ChannelSummary)
    case playlist(PlaylistSummary)

    /// "video:<id>" | "channel:<id>" | "playlist:<id>"
    public var id: String {
        switch self {
        case .video(let video): return "video:\(video.id)"
        case .channel(let channel): return "channel:\(channel.id)"
        case .playlist(let playlist): return "playlist:\(playlist.id)"
        }
    }

    public var video: VideoSummary? {
        if case .video(let video) = self { return video }
        return nil
    }
}

public enum SearchType: String, Codable, CaseIterable, Sendable {
    case all, video, channel, playlist
}

public enum SearchSort: String, Codable, CaseIterable, Sendable {
    case relevance, uploadDate, viewCount
}

public enum SearchDuration: String, Codable, CaseIterable, Sendable {
    case any, short, medium, long
}

public enum SearchUploadDate: String, Codable, CaseIterable, Sendable {
    case any, lastHour, today, thisWeek, thisMonth, thisYear
}

public struct SearchFilter: Codable, Hashable, Sendable {
    public var type: SearchType
    public var sort: SearchSort
    public var duration: SearchDuration
    public var uploadDate: SearchUploadDate

    public init(
        type: SearchType = .all,
        sort: SearchSort = .relevance,
        duration: SearchDuration = .any,
        uploadDate: SearchUploadDate = .any
    ) {
        self.type = type
        self.sort = sort
        self.duration = duration
        self.uploadDate = uploadDate
    }

    /// True when every facet is at its default (no filtering at all).
    public var isDefault: Bool {
        type == .all && sort == .relevance && duration == .any && uploadDate == .any
    }
}

/// What a URL (or pasted link) points at.
public enum ResolvedURL: Hashable, Sendable {
    case video(id: String, startSeconds: Int?)
    /// A video that a link names together with a playlist (`watch?v=…&list=…`): it plays as part of that playlist.
    case videoInPlaylist(id: String, startSeconds: Int?, playlistID: String)
    case channel(id: String)
    case playlist(id: String)
    case search(query: String)
}
