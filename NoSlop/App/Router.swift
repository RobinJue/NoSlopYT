import Foundation
import NoSlopKit
import Observation

/// The four tabs of the root `TabView`.
nonisolated enum AppTab: Hashable, Sendable {
    case home, subscriptions, library, search
}

/// Everything that can be pushed onto a tab's `NavigationStack`. `RouteDestinationView` turns a route into a screen.
nonisolated enum Route: Hashable, Sendable {
    case channel(id: String)
    case playlist(id: String)
    /// A playlist of the signed-in Google account (the summary is enough to show the header while loading).
    case accountPlaylist(PlaylistSummary)
    case localPlaylist(id: UUID)
    case history
    case watchLater
    case likedVideos
    case accountPlaylists
    case downloads
    case subscriptionsManager
    case settings
    case searchResults(query: String)
}

/// Navigation state: the selected tab and one path per tab. Screens never push onto a `NavigationStack` themselves;
/// they call `AppEnvironment.show(_:)` (which minimizes the player first) so every tab and the player overlay
/// navigate the same way.
@MainActor
@Observable
final class Router {
    var selectedTab: AppTab = .home
    var homePath: [Route] = []
    var subscriptionsPath: [Route] = []
    var libraryPath: [Route] = []
    var searchPath: [Route] = []

    /// Pushes onto the selected tab's path.
    func push(_ route: Route) {
        switch selectedTab {
        case .home: homePath.append(route)
        case .subscriptions: subscriptionsPath.append(route)
        case .library: libraryPath.append(route)
        case .search: searchPath.append(route)
        }
    }

    /// Empties a tab's path. `nil` means the selected tab.
    func popToRoot(_ tab: AppTab? = nil) {
        switch tab ?? selectedTab {
        case .home: homePath.removeAll()
        case .subscriptions: subscriptionsPath.removeAll()
        case .library: libraryPath.removeAll()
        case .search: searchPath.removeAll()
        }
    }
}
