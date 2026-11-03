import NoSlopKit
import SwiftUI

/// Turns a `Route` into its screen. Every tab's `NavigationStack` uses it as the destination for `Route`.
struct RouteDestinationView: View {
    let route: Route

    var body: some View {
        switch route {
        case .channel(let id):
            ChannelView(channelID: id)
        case .playlist(let id):
            PlaylistView(playlistID: id)
        case .accountPlaylist(let playlist):
            AccountPlaylistView(playlist: playlist)
        case .localPlaylist(let id):
            LocalPlaylistView(playlistID: id)
        case .history:
            HistoryView()
        case .watchLater:
            WatchLaterView()
        case .likedVideos:
            LikedVideosView()
        case .accountPlaylists:
            AccountPlaylistsView()
        case .downloads:
            DownloadsView()
        case .subscriptionsManager:
            SubscriptionsManagerView()
        case .settings:
            SettingsView()
        case .searchResults(let query):
            SearchResultsView(query: query)
        }
    }
}
