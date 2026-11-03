import Foundation
import NoSlopKit

/// A parsed `noslop://` link: a tab to select, a route to push, or something a YouTube link could also mean.
///
/// - `noslop://tab/<home|subscriptions|library|search>`
/// - `noslop://route/<settings|downloads|history|watchLater|likedVideos|accountPlaylists|subscriptionsManager>`
///   ("watchLater", "watch-later" and "watch_later" are the same name)
/// - `noslop://watch?v=<id>[&t=<seconds>]`, `noslop://channel/<id>`, `noslop://playlist/<id>` and
///   `noslop://search?q=<text>` mean what the same YouTube link means, and are read by the same parser
///   (`YouTubeURL`), so the two cannot disagree about what an id or a time looks like.
///
/// A link that is incomplete or malformed (a video id of the wrong length, a time that is not a number, an unknown
/// name) is not a link at all: `init` returns nil and the app says so instead of guessing.
nonisolated enum AppLink: Equatable, Sendable {
    case tab(AppTab)
    case route(Route)
    case resolved(ResolvedURL)

    static let scheme = "noslop"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }

        /// The first path segment as a name: "watchLater", "watch-later" and "watch_later" are the same.
        var name: String? {
            components.path.split(separator: "/").first.map { $0.lowercased().filter { $0 != "-" && $0 != "_" } }
        }

        switch host {
        case "tab":
            guard let name, let tab = Self.tabs[name] else { return nil }
            self = .tab(tab)
        case "route":
            guard let name, let route = Self.routes[name] else { return nil }
            self = .route(route)
        default:
            guard let resolved = YouTubeURL.resolveLocally(url) else { return nil }
            self = .resolved(resolved)
        }
    }

    private static let tabs: [String: AppTab] = [
        "home": .home,
        "subscriptions": .subscriptions,
        "library": .library,
        "search": .search,
    ]

    private static let routes: [String: Route] = [
        "settings": .settings,
        "downloads": .downloads,
        "history": .history,
        "watchlater": .watchLater,
        "likedvideos": .likedVideos,
        "accountplaylists": .accountPlaylists,
        "subscriptionsmanager": .subscriptionsManager,
    ]
}
