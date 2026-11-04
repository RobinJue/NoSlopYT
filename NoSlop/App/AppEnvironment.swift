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

    /// The signed-in Google account, nil when signed out. Set by `refreshAccount`, `signIn` and `signOut`, and by
    /// `reconcileGoogleAccount` when a call to Google failed because the session had ended.
    private(set) var googleAccount: GoogleAccount?

    /// Why the last link could not be opened, in plain words, for the alert in `RootView`. Nil when there is nothing to
    /// say; `dismissLinkError` clears it.
    private(set) var linkError: String?

    /// The load of the watch details that the player asked for (`loadDetailsForPlayer`).
    @ObservationIgnored private var playerDetailsTask: Task<Void, Never>?

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
            deArrow: deArrow,
            captions: captions,
            library: library,
            settingsStore: settingsStore,
            downloads: downloads
        )
        // With the player minimized (or the app in the background) no watch page is on screen to hand the player the
        // chapters and the up-next list of the video that plays: they are loaded here instead.
        player.detailsNeeded = { [weak self] video in self?.loadDetailsForPlayer(video) }
    }

    // MARK: Construction

    /// `live()`; in Debug builds `preview()` instead when the app was launched with `-mockServices YES`. A Release
    /// build has no way to switch to the mocks.
    static let shared: AppEnvironment = {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "mockServices") { return .preview() }
        #endif
        return .live()
    }()

    /// The real services, and nothing but: no mock, no stub, no test seam. Everything that is not a real service lives
    /// in `preview()`.
    static func live() -> AppEnvironment {
        // No session is passed in: which `URLSession` the kit talks through is `URLSessionHTTPClient`'s decision.
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

        #if DEBUG
        let connection = DebugLaunchHooks.mockConnection
        let youTube = MockYouTubeService(delay: DebugLaunchHooks.mockYouTubeDelay, connection: connection)
        let streams = MockStreamResolver(delay: DebugLaunchHooks.mockStreamDelay)
        let sponsorBlock = MockSponsorBlock(failingFirst: DebugLaunchHooks.flakySponsorBlockFailures)
        let subscriptionFeed: any SubscriptionFeedProviding = LoggingSubscriptionFeed(
            MockSubscriptionFeed(delay: DebugLaunchHooks.mockFeedDelay, connection: connection, cached: DebugLaunchHooks.staleFeedCache)
        )
        let homeFeed: any HomeFeedProviding = LoggingHomeFeed(
            MockHomeFeed(delay: DebugLaunchHooks.mockFeedDelay, connection: connection)
        )
        let auth: any GoogleAuthProviding = MockAuth(signedIn: DebugLaunchHooks.signedIn)
        DebugLaunchHooks.seedDownload(in: scratch.appendingPathComponent("Downloads", isDirectory: true))
        #else
        let youTube = MockYouTubeService()
        let streams = MockStreamResolver()
        let sponsorBlock = MockSponsorBlock()
        let subscriptionFeed: any SubscriptionFeedProviding = MockSubscriptionFeed()
        let homeFeed: any HomeFeedProviding = MockHomeFeed()
        let auth: any GoogleAuthProviding = MockAuth()
        #endif
        let settingsStore = SettingsStore(defaults: defaults)
        let library = LibraryStore(directory: scratch.appendingPathComponent("Library", isDirectory: true))
        let downloads = DownloadManager(
            rootDirectory: scratch.appendingPathComponent("Downloads", isDirectory: true),
            streams: streams,
            sessionConfiguration: .ephemeral
        )

        return AppEnvironment(
            youTube: youTube,
            streams: streams,
            captions: MockCaptions(),
            subscriptionFeed: subscriptionFeed,
            homeFeed: homeFeed,
            sponsorBlock: sponsorBlock,
            deArrow: MockDeArrow(),
            auth: auth,
            account: MockAccountService(),
            library: library,
            settingsStore: settingsStore,
            downloads: downloads
        )
    }

    // MARK: Playing and navigating

    /// Starts `video` in the player (expanded). `queue` plays after it, and `more` supplies the rest of the list the
    /// queue came from while it has pages that are not loaded (a long playlist).
    func open(_ video: VideoSummary, startAt: Double? = nil, queue: [VideoSummary] = [], more: QueueSource? = nil) {
        player.open(video, startAt: startAt, queue: queue, more: more)
    }

    /// Pushes `route` onto the selected tab; an expanded player shrinks to the mini player first so the screen is visible.
    func show(_ route: Route) {
        if player.presentation == .expanded {
            player.minimize()
        }
        router.push(route)
    }

    /// Loads the chapters and the up-next list of `video` for the player (`PlayerController.detailsNeeded`), from the
    /// cache or from YouTube. A request for another video, which means the player has moved on, ends this one.
    private func loadDetailsForPlayer(_ video: VideoSummary) {
        playerDetailsTask?.cancel()
        playerDetailsTask = Task { [weak self] in
            guard let self else { return }
            await WatchDetailsViewModel(video: video).loadForPlayer(using: self)
        }
    }

    // MARK: Subscriptions

    func isSubscribed(_ channelID: String) -> Bool {
        library.isSubscribed(channelID: channelID)
    }

    /// Subscribes to the channel, or unsubscribes when already subscribed.
    ///
    /// Signed in, the change is made on the Google account through the Data API and mirrored in the library
    /// (`.google` source); a failure leaves the library untouched and is thrown (and, when it means the session
    /// ended, `googleAccount` turns nil: see `reconcileGoogleAccount`). Signed out, the subscription is local only.
    /// Unsubscribing a local subscription never touches the Google account.
    func toggleSubscription(_ channel: ChannelRef) async throws {
        if let existing = library.subscriptions.first(where: { $0.id == channel.id }) {
            if case .google(let subscriptionID) = existing.source, googleAccount != nil {
                try await viaAccount { try await $0.unsubscribe(subscriptionID: subscriptionID) }
            }
            library.unsubscribe(channelID: channel.id)
            return
        }

        let source: SubscriptionSource
        if googleAccount != nil {
            source = .google(subscriptionID: try await viaAccount { try await $0.subscribe(channelID: channel.id) })
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

    /// Reads the signed-in account and, when there is one, syncs the Google subscriptions into the library. A sync that
    /// fails is not reported here: at launch and on pull to refresh the library just keeps what it had.
    func refreshAccount() async {
        googleAccount = await auth.currentAccount()
        if googleAccount != nil {
            await syncGoogleSubscriptions()
        }
    }

    /// Runs the Google sign-in with the Client ID from Settings, then imports the account's subscriptions.
    /// Throws `.googleNotConfigured` while no Client ID is set, and `.cancelled` when the user backs out.
    ///
    /// The account is signed in once the sign-in page is done. If the import of its subscriptions then fails for a
    /// reason the viewer can act on (`NoSlopError.isWorthShowingAfterSignIn`: above all `.dataAPINotEnabled`, the
    /// Google project's YouTube Data API is not turned on), that error is thrown as well, so it reaches the sign-in
    /// alert instead of leaving a signed-in Library with no subscriptions and no word why. The account stays signed in.
    func signIn(authenticator: any WebAuthenticating) async throws {
        let clientID = settings.googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw NoSlopError.googleNotConfigured }
        googleAccount = try await auth.signIn(clientID: clientID, authenticator: authenticator)
        if let failure = await syncGoogleSubscriptions(), NoSlopError.isWorthShowingAfterSignIn(failure) {
            throw failure
        }
    }

    /// Signs out. Subscriptions that came from the account stay as local ones, so the feed never vanishes.
    /// `auth.signOut()` returns as soon as the credentials are gone, without waiting for Google to answer the
    /// revocation, so the screens turn to the signed-out state at once.
    func signOut() async {
        await auth.signOut()
        googleAccount = nil
        library.convertGoogleSubscriptionsToLocal()
    }

    /// Imports the account's subscriptions (see `LibraryStore.syncGoogleSubscriptions`: a list that the viewer's own
    /// subscribing or unsubscribing overtook is fetched again, not applied). A failed sync keeps the subscriptions the
    /// library already has. The error is returned for `signIn` to report, and is left alone by the other callers. It may
    /// mean that Google ended the session, so the account is looked at again.
    @discardableResult
    private func syncGoogleSubscriptions() async -> (any Error)? {
        do {
            try await library.syncGoogleSubscriptions { [account] in try await account.subscriptions() }
            return nil
        } catch {
            await reconcileGoogleAccount()
            return error
        }
    }

    /// Runs a call on the Google account. When it fails, the account is looked at again before the error goes on to
    /// the caller, so the screens already show the signed-out state when the failure was a session that had ended.
    ///
    /// Every screen that talks to the account goes through this, none calls `account` directly.
    func viaAccount<Value>(_ call: (any YouTubeAccountService) async throws -> Value) async throws -> Value {
        do {
            return try await call(account)
        } catch {
            await reconcileGoogleAccount()
            throw error
        }
    }

    /// Makes `googleAccount` say what the auth service says, after a call to Google failed. The auth service signs
    /// itself out when Google refuses to renew the session (`invalid_grant`: the Keychain is cleared and
    /// `.notSignedIn` is thrown), and nothing else in the app would notice, so the screens would go on showing an
    /// account that can no longer be used.
    ///
    /// Like a sign-out by the user, this keeps the subscriptions that came from the account, as local ones. A
    /// credential store that could not be read for a moment looks the same as a sign-out from here; the next
    /// `refreshAccount` or sign-in brings the `.google` subscriptions back, so nothing is lost by it.
    ///
    /// `viaAccount` calls this when a call fails.
    func reconcileGoogleAccount() async {
        let current = await auth.currentAccount()
        guard current != googleAccount else { return }
        googleAccount = current
        if current == nil {
            library.convertGoogleSubscriptionsToLocal()
        }
    }

    // MARK: Links

    /// Opens what a URL points at: the app's own `noslop://` links (see `AppLink`), or a YouTube link: a video
    /// (`/watch`, `youtu.be`, `/shorts`, `/live`, `/embed`, with its `t=` start time), a channel (`/channel/<id>`,
    /// `/@handle`), a playlist or a search. YouTube links are recognised locally when possible; a `/@handle` and
    /// the like are resolved over the network.
    ///
    /// A link that cannot be opened (not a YouTube link, incomplete, or YouTube cannot be reached to resolve it)
    /// opens nothing and sets `linkError`, which `RootView` shows in an alert.
    func handleOpenURL(_ url: URL) async {
        linkError = nil
        switch url.scheme?.lowercased() {
        case AppLink.scheme:
            if let link = AppLink(url: url) {
                perform(link)
            } else {
                linkError = Self.unopenableLinkMessage
            }
        case "http", "https":
            await openWebLink(url)
        default:
            linkError = Self.unopenableLinkMessage
        }
    }

    /// The alert for `linkError` was dismissed.
    func dismissLinkError() {
        linkError = nil
    }

    private static let unopenableLinkMessage =
        "No Slop opens links to YouTube videos, channels and playlists. This one is something else, or it is incomplete."

    private func openWebLink(_ url: URL) async {
        if let resolved = YouTubeURL.resolveLocally(url) {
            openResolved(resolved)
            return
        }
        // A `/@handle` or a custom channel address: only YouTube can say which channel that is.
        do {
            if let resolved = try await youTube.resolve(url: url) {
                openResolved(resolved)
            } else {
                linkError = Self.unopenableLinkMessage
            }
        } catch is CancellationError {
            // The caller went away; nobody is waiting for an answer.
        } catch NoSlopError.cancelled {
            // Same, as reported by the kit.
        } catch {
            linkError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func perform(_ link: AppLink) {
        switch link {
        case .tab(let tab):
            if player.presentation == .expanded {
                player.minimize()
            }
            router.selectedTab = tab
        case .route(let route):
            show(route)
        case .resolved(let resolved):
            openResolved(resolved)
        }
    }

    /// Opens what a resolved link points at. A video opens at once and without waiting for anything: the player fills
    /// in its title and channel as they arrive (see `knownSummary`), so no late answer can replace what the viewer
    /// chose in the meantime.
    private func openResolved(_ resolved: ResolvedURL) {
        switch resolved {
        case .video(let id, let startSeconds):
            // YouTube's resolver hands back whatever the link said (`watch?v=abc` resolves to the video "abc"), so a
            // malformed id is caught here instead of opening a player that can only fail.
            guard Self.isVideoID(id) else {
                linkError = Self.unopenableLinkMessage
                return
            }
            open(knownSummary(forID: id) ?? VideoSummary(id: id, title: ""), startAt: startSeconds.map(Double.init))
        case .channel(let id):
            show(.channel(id: id))
        case .playlist(let id):
            show(.playlist(id: id))
        case .search(let query):
            router.showRoot(of: .search)
            show(.searchResults(query: query))
        }
    }

    /// A link only carries the video id, but the player, the history and the mini player want a title and a channel. What
    /// the library already knows about the video (history, Watch Later, downloads) is used as it is. For any other video
    /// the player opens a bare summary with an empty title: it shows a placeholder, and the title, the channel, the views
    /// and the age arrive with the stream (`PlayerController.accept`) and the watch details
    /// (`PlayerController.complete(with:)`).
    private func knownSummary(forID id: String) -> VideoSummary? {
        library.history.first(where: { $0.id == id })?.video
            ?? library.watchLater.first(where: { $0.id == id })
            ?? downloads.items.first(where: { $0.video.id == id })?.video
    }

    // MARK: Helpers

    /// A video id is eleven letters, digits, "-" and "_".
    private static func isVideoID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                true
            default:
                false
            }
        }
    }

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
