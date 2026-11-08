import Foundation
import NoSlopKit

// The words the filter sheet shows for the kit's search facets.

extension SearchType {
    var label: String {
        switch self {
        case .all: return "All"
        case .video: return "Videos"
        case .channel: return "Channels"
        case .playlist: return "Playlists"
        }
    }
}

extension SearchSort {
    var label: String {
        switch self {
        case .relevance: return "Relevance"
        case .uploadDate: return "Upload date"
        case .viewCount: return "View count"
        }
    }
}

extension SearchDuration {
    var label: String {
        switch self {
        case .any: return "Any"
        case .short: return "Under 4 minutes"
        case .medium: return "4\u{2013}20 minutes"
        case .long: return "Over 20 minutes"
        }
    }
}

extension SearchUploadDate {
    var label: String {
        switch self {
        case .any: return "Any time"
        case .lastHour: return "Last hour"
        case .today: return "Today"
        case .thisWeek: return "This week"
        case .thisMonth: return "This month"
        case .thisYear: return "This year"
        }
    }
}

extension SearchFilter {
    /// Duration and upload date only apply to videos; for a channel or playlist search they are dropped, so a stale
    /// choice cannot silently narrow the next search.
    var normalized: SearchFilter {
        guard type == .channel || type == .playlist else { return self }
        var copy = self
        copy.duration = .any
        copy.uploadDate = .any
        return copy
    }

    /// How many facets differ from the default, for the badge on the filter button.
    var activeCount: Int {
        [type != .all, sort != .relevance, duration != .any, uploadDate != .any].filter { $0 }.count
    }
}

extension ResolvedURL {
    /// The app's own `noslop://` link for the same target, which `AppEnvironment.handleOpenURL` knows how to open.
    var appLink: URL? {
        var components = URLComponents()
        components.scheme = "noslop"
        switch self {
        case .video(let id, let startSeconds):
            components.host = "watch"
            components.queryItems = [URLQueryItem(name: "v", value: id)]
                + (startSeconds.map { [URLQueryItem(name: "t", value: String($0))] } ?? [])
        case .videoInPlaylist(let id, let startSeconds, let playlistID):
            components.host = "watch"
            components.queryItems = [URLQueryItem(name: "v", value: id)]
                + (startSeconds.map { [URLQueryItem(name: "t", value: String($0))] } ?? [])
                + [URLQueryItem(name: "list", value: playlistID)]
        case .channel(let id):
            components.host = "channel"
            components.path = "/" + id
        case .playlist(let id):
            components.host = "playlist"
            components.path = "/" + id
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return components.url
    }
}
