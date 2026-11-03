import Foundation
import NoSlopKit
import Observation

/// The app's composition root: every service, store and controller, created once and handed to the view tree with
/// `.environment(env)`. Views read it with `@Environment(AppEnvironment.self)`.
///
/// `live()` wires the real services; `preview()` wires the mocks (used for SwiftUI previews and for launches with
/// `-mockServices YES`), with a throw-away library and settings so nothing touches the user's data.
@MainActor
@Observable
final class AppEnvironment {
    let youTube: any YouTubeService
    let streams: any StreamResolving
    let captions: any CaptionsProviding
    let subscriptionFeed: any SubscriptionFeedProviding
    let homeFeed: any HomeFeedProviding
    let sponsorBlock: any SponsorBlockProviding
    let deArrow: any DeArrowProviding
    let auth: any GoogleAuthProviding
    let account: any YouTubeAccountService
    let library: LibraryStore
    let settingsStore: SettingsStore
    let downloads: DownloadManager
    let player: PlayerController
    let router: Router

    /// The signed-in Google account, nil when signed out. Set by `refreshAccount`, `signIn` and `signOut`.
    private(set) var googleAccount: GoogleAccount?

    /// `settingsStore.settings`.
    var settings: AppSettings { settingsStore.settings }

    /// The feed filter for the current settings; "hide watched" uses the finished videos of the history.
    /// Reading it inside `body` tracks both the settings and the history. Build it once per refresh, not per row.
    var contentFilter: ContentFilter {
        ContentFilter(
            settings: settings,
            watchedIDs: Set(library.history.lazy.filter(\.isFinished).map(\.id))
        )
    }

    init(
        youTube: any YouTubeService,
        streams: any StreamResolving,
        captions: any CaptionsProviding,
        subscriptionFeed: any SubscriptionFeedProviding,
        homeFeed: any HomeFeedProviding,
        sponsorBlock: any SponsorBlockProviding,
        deArrow: any DeArrowProviding,
        auth: any GoogleAuthProviding,
        account: any YouTubeAccountService,
        library: LibraryStore,
        settingsStore: SettingsStore,
        downloads: DownloadManager,
        router: Router = Router()
    ) {
        self.youTube = youTube
        self.streams = streams
        self.captions = captions
        self.subscriptionFeed = subscriptionFeed
        self.homeFeed = homeFeed
        self.sponsorBlock = sponsorBlock
        self.deArrow = deArrow
        self.auth = auth
        self.account = account
        self.library = library
        self.settingsStore = settingsStore
        self.downloads = downloads
        self.router = router
        self.player = PlayerController(
            streams: streams,
            sponsorBlock: sponsorBlock,
            captions: captions,
            library: library,
            settingsStore: settingsStore,
            downloads: downloads
        )
    }

    // MARK: Construction

    /// `live()`, or `preview()` when the app was launched with `-mockServices YES`.
    static let shared: AppEnvironment = UserDefaults.standard.bool(forKey: "mockServices") ? .preview() : .live()

    /// The real services.
    static func live() -> AppEnvironment {
        let http = URLSessionHTTPClient()
        let settingsStore = SettingsStore()

        let deviceConfig = InnerTubeConfig.fromLocale()
        let config = InnerTubeConfig(
            hl: nonEmpty(settingsStore.settings.contentLanguage) ?? deviceConfig.hl,
            gl: nonEmpty(settingsStore.settings.contentRegion) ?? deviceConfig.gl
        )
        let client = InnerTubeClient(http: http, config: config)
        let youTube = InnerTubeYouTubeService(client: client, http: http)
        let streams = InnerTubeStreamResolver(client: client)
        let captions = CaptionsService(http: http)
        let rss = RSSFeedFetcher(http: http)

        let auth = GoogleOAuthService(http: http, store: KeychainTokenStore())
        let account = YouTubeDataAPIClient(http: http, auth: auth)

        let subscriptionFeed = SubscriptionFeedService(
            rss: rss,
            account: account,
            cacheURL: directory(.cachesDirectory).appendingPathComponent("subscription-feed.json")
        )
        let homeFeed = HomeFeedService(youTube: youTube)
        let sponsorBlock = SponsorBlockClient(http: http)
        let deArrow = DeArrowClient(http: http)

        let library = LibraryStore(directory: directory(.applicationSupportDirectory, appending: "NoSlop"))
        let downloads = DownloadManager(
            rootDirectory: directory(.documentDirectory, appending: "NoSlop Downloads"),
            streams: streams
        )

        return AppEnvironment(
            youTube: youTube,
            streams: streams,
            captions: captions,
            subscriptionFeed: subscriptionFeed,
            homeFeed: homeFeed,
            sponsorBlock: sponsorBlock,
            deArrow: deArrow,
            auth: auth,
            account: account,
            library: library,
            settingsStore: settingsStore,
            downloads: downloads
        )
    }

    /// The mock services, with an empty library, default settings and an in-memory download session that live in a
    /// scratch location of their own.
    static func preview() -> AppEnvironment {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSlop-Preview-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "com.robinjungerich.noslopyt.preview.\(UUID().uuidString)") ?? .standard

        let streams = MockStreamResolver()
        let settingsStore = SettingsStore(defaults: defaults)
        let library = LibraryStore(directory: scratch.appendingPathComponent("Library", isDirectory: true))
        let downloads = DownloadManager(
            rootDirectory: scratch.appendingPathComponent("Downloads", isDirectory: true),
            streams: streams,
            sessionConfiguration: .ephemeral
        )

        return AppEnvironment(
            youTube: MockYouTubeService(),
            streams: streams,
            captions: MockCaptions(),
            subscriptionFeed: MockSubscriptionFeed(),
            homeFeed: MockHomeFeed(),
            sponsorBlock: MockSponsorBlock(),
            deArrow: MockDeArrow(),
            auth: MockAuth(),
            account: MockAccountService(),
            library: library,
            settingsStore: settingsStore,
            downloads: downloads
        )
    }

    // MARK: Playing and navigating

    /// Starts `video` in the player (expanded). `queue` plays after it.
    func open(_ video: VideoSummary, startAt: Double? = nil, queue: [VideoSummary] = []) {
        player.open(video, startAt: startAt, queue: queue)
    }

    /// Pushes `route` onto the selected tab; an expanded player shrinks to the mini player first so the screen is visible.
    func show(_ route: Route) {
        if player.presentation == .expanded {
            player.minimize()
        }
        router.push(route)
    }

    // MARK: Subscriptions

    func isSubscribed(_ channelID: String) -> Bool {
        library.isSubscribed(channelID: channelID)
    }

    /// Subscribes to the channel, or unsubscribes when already subscribed.
    ///
    /// Signed in, the change is made on the Google account through the Data API and mirrored in the library
    /// (`.google` source); a failure leaves the library untouched and is thrown. Signed out, the subscription is
    /// local only. Unsubscribing a local subscription never touches the Google account.
    func toggleSubscription(_ channel: ChannelRef) async throws {
        if let existing = library.subscriptions.first(where: { $0.id == channel.id }) {
            if case .google(let subscriptionID) = existing.source, googleAccount != nil {
                try await account.unsubscribe(subscriptionID: subscriptionID)
            }
            library.unsubscribe(channelID: channel.id)
            return
        }

        let source: SubscriptionSource
        if googleAccount != nil {
            source = .google(subscriptionID: try await account.subscribe(channelID: channel.id))
        } else {
            source = .local
        }
        library.subscribe(
            SubscribedChannel(
                id: channel.id,
                name: channel.name,
                avatarURL: channel.avatarURL,
                source: source,
                subscribedAt: Date()
            )
        )
    }

    // MARK: Google account

    /// Reads the signed-in account and, when there is one, syncs the Google subscriptions into the library.
    func refreshAccount() async {
        googleAccount = await auth.currentAccount()
        if googleAccount != nil {
            await syncGoogleSubscriptions()
        }
    }

    /// Runs the Google sign-in with the Client ID from Settings, then imports the account's subscriptions.
    /// Throws `.googleNotConfigured` while no Client ID is set, and `.cancelled` when the user backs out.
    func signIn(authenticator: any WebAuthenticating) async throws {
        let clientID = settings.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw NoSlopError.googleNotConfigured }
        googleAccount = try await auth.signIn(clientID: clientID, authenticator: authenticator)
        await syncGoogleSubscriptions()
    }

    /// Signs out. Subscriptions that came from the account stay as local ones, so the feed never vanishes.
    func signOut() async {
        await auth.signOut()
        googleAccount = nil
        library.convertGoogleSubscriptionsToLocal()
    }

    /// A failed sync keeps the subscriptions the library already has.
    private func syncGoogleSubscriptions() async {
        guard let channels = try? await account.subscriptions() else { return }
        library.replaceGoogleSubscriptions(channels)
    }

    // MARK: Links

    /// Opens what a URL points at: the app's own `noslop://` links, or a YouTube link (video, channel, playlist,
    /// search). YouTube links are recognised locally when possible and otherwise resolved over the network.
    ///
    /// `noslop://watch?v=<id>[&t=<seconds>]`, `noslop://channel/<id>`, `noslop://playlist/<id>`,
    /// `noslop://search?q=<text>`, `noslop://tab/<home|subscriptions|library|search>` and
    /// `noslop://route/<settings|downloads|history|watchLater|likedVideos|accountPlaylists|subscriptionsManager>`.
    func handleOpenURL(_ url: URL) async {
        if let link = AppLink(url: url) {
            await perform(link)
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        if let resolved = YouTubeURL.resolveLocally(url) {
            await openResolved(resolved)
        } else if let resolved = try? await youTube.resolve(url: url) {
            await openResolved(resolved)
        }
    }

    private func perform(_ link: AppLink) async {
        switch link {
        case .tab(let tab):
            if player.presentation == .expanded {
                player.minimize()
            }
            router.selectedTab = tab
        case .route(let route):
            show(route)
        case .resolved(let resolved):
            await openResolved(resolved)
        }
    }

    private func openResolved(_ resolved: ResolvedURL) async {
        switch resolved {
        case .video(let id, let startSeconds):
            let video = await videoSummary(forID: id)
            open(video, startAt: startSeconds.map(Double.init))
        case .channel(let id):
            show(.channel(id: id))
        case .playlist(let id):
            show(.playlist(id: id))
        case .search(let query):
            router.selectedTab = .search
            router.popToRoot(.search)
            show(.searchResults(query: query))
        }
    }

    /// A link only carries the video id, but the player, the history and the mini player need a title and channel.
    /// Uses what the library already knows, else asks YouTube for a few seconds, else falls back to the bare id.
    private func videoSummary(forID id: String) async -> VideoSummary {
        if let known = library.history.first(where: { $0.id == id })?.video
            ?? library.watchLater.first(where: { $0.id == id })
            ?? downloads.items.first(where: { $0.video.id == id })?.video {
            return known
        }
        return await Self.fetchSummary(id: id, from: youTube) ?? VideoSummary(id: id, title: "")
    }

    private static func fetchSummary(id: String, from service: any YouTubeService) async -> VideoSummary? {
        await withTaskGroup(of: VideoSummary?.self) { group in
            group.addTask { try? await service.videoDetails(id: id).summary }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            // Whichever finishes first wins: the details, a failed lookup (nil), or the timeout (nil).
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// A per-app folder in a standard location, created when missing. Falls back to the temporary directory.
    private static func directory(_ base: FileManager.SearchPathDirectory, appending component: String? = nil) -> URL {
        let fileManager = FileManager.default
        var url = (try? fileManager.url(for: base, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        if let component {
            url.appendPathComponent(component, isDirectory: true)
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}

/// A parsed `noslop://` link: a tab to select, a route to push, or something a YouTube link could also mean.
nonisolated enum AppLink: Equatable, Sendable {
    case tab(AppTab)
    case route(Route)
    case resolved(ResolvedURL)

    static let scheme = "noslop"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)

        func query(_ name: String) -> String? {
            guard let value = components.queryItems?.first(where: { $0.name == name })?.value, !value.isEmpty else { return nil }
            return value
        }
        /// "watchLater", "watch-later" and "watch_later" are the same name.
        func normalized(_ name: String?) -> String? {
            name?.lowercased().filter { $0 != "-" && $0 != "_" }
        }

        switch host {
        case "watch":
            guard let id = query("v") ?? parts.first else { return nil }
            let start = (query("t") ?? query("start")).flatMap(Self.seconds(from:))
            self = .resolved(.video(id: id, startSeconds: start))
        case "channel":
            guard let id = parts.first ?? query("id") else { return nil }
            self = .resolved(.channel(id: id))
        case "playlist":
            guard let id = parts.first ?? query("list") else { return nil }
            self = .resolved(.playlist(id: id))
        case "search":
            guard let text = query("q") else { return nil }
            self = .resolved(.search(query: text))
        case "tab":
            guard let name = normalized(parts.first), let tab = Self.tabs[name] else { return nil }
            self = .tab(tab)
        case "route":
            guard let name = normalized(parts.first), let route = Self.routes[name] else { return nil }
            self = .route(route)
        default:
            return nil
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

    /// "90", "90s", "1m30s", "1h2m3s" -> seconds; nil for anything else.
    static func seconds(from text: String) -> Int? {
        if let plain = Int(text) { return plain }
        var total = 0
        var number = 0
        var sawUnit = false
        for character in text.lowercased() {
            if character.isASCII, let digit = character.wholeNumberValue {
                number = number * 10 + digit
                continue
            }
            switch character {
            case "h": total += number * 3_600
            case "m": total += number * 60
            case "s": total += number
            default: return nil
            }
            number = 0
            sawUnit = true
        }
        return sawUnit ? total : nil
    }
}
