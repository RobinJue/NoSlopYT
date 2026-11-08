import Foundation
import NoSlopKit
import Observation
import UIKit

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
    /// The optional YouTube recommendations connection (YouTube's TV sign-in), separate from `auth`.
    let recommendationsAuth: any RecommendationsAuthProviding
    let recommendations: any RecommendationsProviding
    let watchReporter: any WatchReporting
    let library: LibraryStore
    let settingsStore: SettingsStore
    /// The last `refreshAccount` ran while protected data was unavailable, so what it read is not to be trusted.
    private var accountReadWhileLocked = false
    let downloads: DownloadManager
    let player: PlayerController
    let router: Router

    /// The signed-in Google account, nil when signed out. Set by `refreshAccount`, `signIn` and `signOut`, and by
    /// `reconcileGoogleAccount` when a call to Google failed because the session had ended.
    private(set) var googleAccount: GoogleAccount?

    /// The connected YouTube recommendations account, nil when not connected. Set by `refreshRecommendationsAccount`,
    /// the connect flow and `disconnectRecommendations`. A TV failure never touches `googleAccount`, and the other
    /// way round.
    private(set) var recommendationsAccount: TVAccount?

    /// The ids of the Home videos that came from YouTube's own Home (they get the card actions). Emptied on disconnect.
    var recommendationCardIDs: Set<String> = []

    /// What the Diagnostics screen lists; `refreshRecommendationsDiagnostics` fills it.
    var recommendationsDiagnostics = RecommendationsDiagnostics()

    /// Counts the changes of the recommendations connection (connected, disconnected), so Home can load again.
    private(set) var recommendationsRevision = 0

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
        recommendationsAuth: any RecommendationsAuthProviding,
        recommendations: any RecommendationsProviding,
        watchReporter: any WatchReporting,
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
        self.recommendationsAuth = recommendationsAuth
        self.recommendations = recommendations
        self.watchReporter = watchReporter
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
        // An app that iOS starts in the background before the first unlock cannot read its settings yet: the store then
        // saves nothing until `reloadAfterUnlock` has read them again.
        let settingsStore = SettingsStore(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)

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
        // The TV connection has its own cookie-free session and its own Keychain item.
        let recommendationsAuth = TVAuthService(http: URLSessionHTTPClient.isolated(), store: KeychainTVTokenStore())

        let subscriptionFeed = SubscriptionFeedService(
            rss: rss,
            account: account,
            cacheURL: directory(.cachesDirectory).appendingPathComponent("subscription-feed.json")
        )
        let homeFeed = HomeFeedService(youTube: youTube)
        let sponsorBlock = SponsorBlockClient(http: http)
        let deArrow = DeArrowClient(http: http)

        let library = LibraryStore(directory: directory(.applicationSupportDirectory, appending: "NoSlop"))
        // A download is played offline, so the SponsorBlock segments, the chapters and the captions of its video are fetched
        // when the download starts, while there is a connection, and kept with it.
        let downloadExtras = DownloadExtrasFetcher(
            sponsorBlock: sponsorBlock,
            youTube: youTube,
            captions: captions,
            preferredCaptionLanguage: { settingsStore.settings.preferredCaptionLanguage },
            sponsorBlockEnabled: { settingsStore.settings.sponsorBlockEnabled }
        )
        let downloads = DownloadManager(
            rootDirectory: directory(.documentDirectory, appending: "NoSlop Downloads"),
            streams: streams,
            extras: downloadExtras
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
            recommendationsAuth: recommendationsAuth,
            recommendations: UnavailableRecommendations(),
            // Part B replaces the line above, Part C the line below.
            watchReporter: NoWatchReporter(),
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
        // The services a playing video asks (`-offlinePlayerServices YES` makes them fail like the network does).
        let playerConnection = DebugLaunchHooks.playerConnection
        let youTube = MockYouTubeService(delay: DebugLaunchHooks.mockYouTubeDelay, connection: connection)
        let streams = MockStreamResolver(delay: DebugLaunchHooks.mockStreamDelay, connection: playerConnection)
        let sponsorBlock = MockSponsorBlock(failingFirst: DebugLaunchHooks.flakySponsorBlockFailures, connection: playerConnection)
        let captions: any CaptionsProviding = MockCaptions(connection: playerConnection)
        let subscriptionFeed: any SubscriptionFeedProviding = LoggingSubscriptionFeed(
            MockSubscriptionFeed(delay: DebugLaunchHooks.mockFeedDelay, connection: connection, cached: DebugLaunchHooks.staleFeedCache)
        )
        let homeFeed: any HomeFeedProviding = LoggingHomeFeed(
            MockHomeFeed(delay: DebugLaunchHooks.mockFeedDelay, connection: connection)
        )
        let auth: any GoogleAuthProviding = MockAuth(signedIn: DebugLaunchHooks.signedIn)
        let deArrow: any DeArrowProviding = LoggingDeArrow(
            MockDeArrow(delay: DebugLaunchHooks.mockDeArrowDelay, connection: DebugLaunchHooks.deArrowConnection)
        )
        let account: any YouTubeAccountService = MockAccountService(delay: DebugLaunchHooks.mockAccountDelay)
        let recommendationsAuth: any RecommendationsAuthProviding = MockRecommendationsAuth(
            connected: DebugLaunchHooks.recommendationsConnected, delay: DebugLaunchHooks.recommendationsDelay
        )
        DebugLaunchHooks.seedDownload(in: scratch.appendingPathComponent("Downloads", isDirectory: true))
        #else
        let youTube = MockYouTubeService()
        let streams = MockStreamResolver()
        let sponsorBlock = MockSponsorBlock()
        let captions: any CaptionsProviding = MockCaptions()
        let subscriptionFeed: any SubscriptionFeedProviding = MockSubscriptionFeed()
        let homeFeed: any HomeFeedProviding = MockHomeFeed()
        let auth: any GoogleAuthProviding = MockAuth()
        let deArrow: any DeArrowProviding = MockDeArrow()
        let account: any YouTubeAccountService = MockAccountService()
        let recommendationsAuth: any RecommendationsAuthProviding = MockRecommendationsAuth()
        #endif
        let recommendations: any RecommendationsProviding = MockRecommendations()
        let watchReporter: any WatchReporting = MockWatchReporter()
        let settingsStore = SettingsStore(defaults: defaults)
        let library = LibraryStore(directory: scratch.appendingPathComponent("Library", isDirectory: true))
        let downloads = DownloadManager(
            rootDirectory: scratch.appendingPathComponent("Downloads", isDirectory: true),
            streams: streams,
            sessionConfiguration: .ephemeral
        )
        #if DEBUG
        DebugLaunchHooks.seedDownloadExtras(into: downloads)
        #endif

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
            recommendationsAuth: recommendationsAuth,
            recommendations: recommendations,
            watchReporter: watchReporter,
            library: library,
            settingsStore: settingsStore,
            downloads: downloads
        )
    }

    // MARK: Playing and navigating

    /// Starts `video` in the player (expanded). `queue` plays after it, and `more` supplies the rest of the list the
    /// queue came from while it has pages that are not loaded (a long playlist). `queueName` is what the watch page calls
    /// that list ("Playing from <name>").
    func open(
        _ video: VideoSummary,
        startAt: Double? = nil,
        queue: [VideoSummary] = [],
        more: QueueSource? = nil,
        queueName: String? = nil
    ) {
        player.open(video, startAt: startAt, queue: queue, more: more, queueName: queueName)
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
    ///
    /// When there is no account, the subscriptions that came from the account become local ones, as after a sign-out:
    /// the session may have ended while the app was not looking (Google refused to renew it, or the app's data was
    /// restored onto a device without its Keychain item), and an Unsubscribe made on a `.google` entry then would be
    /// undone by the next sign-in. This is done only while protected data is available: a Keychain that cannot be read
    /// before the first unlock says nothing about the session. `reloadAfterUnlock` reads the account again then.
    func refreshAccount() async {
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        accountReadWhileLocked = !protectedDataAvailable
        googleAccount = await auth.currentAccount()
        if googleAccount != nil {
            await syncGoogleSubscriptions()
        } else if protectedDataAvailable {
            library.convertGoogleSubscriptionsToLocal()
        }
    }

    /// Reads again what could not be read because the app was started before the first unlock after a restart (iOS
    /// does that for a finished background download): the library files, the settings and, if the account was read
    /// then, the account. In this order. The app calls it when protected data becomes available and when the app
    /// becomes active; it is cheap when nothing was missed.
    func reloadAfterUnlock() async {
        library.reloadIfUnreadable()
        settingsStore.reloadIfNeeded(protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable)
        if accountReadWhileLocked, UIApplication.shared.isProtectedDataAvailable {
            await refreshAccount()
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

    // MARK: YouTube recommendations

    /// Reads the connected account from the Keychain; no network traffic. Called at launch.
    func refreshRecommendationsAccount() async {
        recommendationsAccount = await recommendationsAuth.currentAccount()
    }

    /// Called by the connect flow after the sign-in finished.
    func recommendationsConnected(_ account: TVAccount) {
        recommendationsAccount = account
        recommendationsRevision += 1
    }

    /// Disconnects: revokes the grant (best effort), clears the stored tokens, the card handles, the cached Home and
    /// the pending reports, and lets Home load again. Never touches the Google account.
    /// - Returns: whether Google confirmed the revoke (the connection is gone on this device either way).
    @discardableResult
    func disconnectRecommendations() async -> Bool {
        let revoked = await recommendationsAuth.disconnect()
        await recommendations.clearAccountData()
        await watchReporter.clearAccountData()
        recommendationCardIDs = []
        recommendationsAccount = nil
        recommendationsDiagnostics = RecommendationsDiagnostics()
        recommendationsRevision += 1
        return revoked
    }

    /// Reads the Diagnostics numbers again.
    func refreshRecommendationsDiagnostics() async {
        var diagnostics = await recommendations.diagnostics()
        diagnostics.lastReport = await watchReporter.outcome()
        diagnostics.pausedReporting = await watchReporter.isPaused()
        diagnostics.tokenSecondsLeft = await recommendationsAuth.secondsLeft()
        recommendationsDiagnostics = diagnostics
    }

    // MARK: Links

    /// Opens what a URL points at: the app's own `noslop://` links (see `AppLink`), or a YouTube link: a video
    /// (`/watch`, `youtu.be`, `/shorts`, `/live`, `/embed`, with its `t=` start time), a channel (`/channel/<id>`,
    /// `/@handle`), a playlist or a search. YouTube links are recognised locally when possible; a `/@handle` and
    /// the like are resolved over the network.
    ///
    /// A link that cannot be opened (not a YouTube link, incomplete, or YouTube cannot be reached to resolve it)
    /// opens nothing and sets `linkError`, which `RootView` shows in an alert.
    ///
    /// A link that has to wait for YouTube's answer (`openWebLink`) is dropped when the answer comes after the viewer
    /// has moved on: another link was opened, or the viewer switched tab, pushed or popped a screen or opened a video.
    func handleOpenURL(_ url: URL) async {
        linkError = nil
        linkAddress = Self.isYouTubeWebLink(url) ? url : nil
        linksHandled += 1
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

    /// The web link behind `linkError`, which the alert can offer to open on YouTube. Nil for a `noslop://` link and
    /// while there is no error.
    var linkErrorWebURL: URL? {
        linkError == nil ? nil : linkAddress
    }

    /// The YouTube http(s) link `handleOpenURL` was given last; nil when the last link was another kind or another site.
    @ObservationIgnored private var linkAddress: URL?

    /// Only an http(s) link on a YouTube host may be offered as "Open on YouTube"; another site's link would open that
    /// site under the wrong label.
    private static func isYouTubeWebLink(_ url: URL) -> Bool {
        SearchInput.isYouTubeHost(of: url)
    }

    private static let unopenableLinkMessage =
        "No Slop opens links to YouTube videos, channels and playlists. This one is something else, or it is incomplete."

    /// How many links `handleOpenURL` has been given. A link that waits for YouTube compares it afterwards, to see whether
    /// the viewer opened another link while it waited.
    @ObservationIgnored private var linksHandled = 0

    private func openWebLink(_ url: URL) async {
        if let resolved = YouTubeURL.resolveLocally(url) {
            openResolved(resolved)
            return
        }
        // A `/@handle` or a custom channel address: only YouTube can say which channel that is. The answer can take a
        // while and nothing on screen shows that a link is being opened, so the viewer goes on meanwhile.
        let link = linksHandled
        let placeOfViewer = ViewerPlace(self)
        do {
            let resolved = try await youTube.resolve(url: url)
            // Another link was opened meanwhile: this answer is to a link nobody waits for any more.
            guard link == linksHandled else { return }
            if let resolved {
                // The viewer has gone elsewhere since (another tab, a screen pushed or popped, a video opened): a channel
                // page that appears now would pull them away from what they chose. Video links open at once for the same
                // reason (see `openResolved`).
                guard !ViewerPlace(self).hasMoved(since: placeOfViewer) else { return }
                openResolved(resolved)
            } else {
                linkError = Self.unopenableLinkMessage
            }
        } catch is CancellationError {
            // The caller went away; nobody is waiting for an answer.
        } catch NoSlopError.cancelled {
            // Same, as reported by the kit.
        } catch {
            // A late failure of a link that was replaced by another one is not news; it would also replace that one's
            // own message.
            guard link == linksHandled else { return }
            linkError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Where the viewer is, as far as a link that waits for YouTube needs to know.
    private struct ViewerPlace {
        private let tab: AppTab
        private let paths: [[Route]]
        private let videoID: String?
        private let isPlayerExpanded: Bool

        init(_ env: AppEnvironment) {
            let router = env.router
            tab = router.selectedTab
            paths = [router.homePath, router.subscriptionsPath, router.libraryPath, router.searchPath]
            videoID = env.player.currentVideo?.id
            isPlayerExpanded = env.player.presentation == .expanded
        }

        /// The viewer is somewhere else than at `earlier`: on another tab, with a screen pushed or popped (on any tab),
        /// with another video loaded, or in the player after not being there. A viewer who minimizes the player to look at
        /// the tabs is still waiting for the link, so that is not leaving.
        func hasMoved(since earlier: ViewerPlace) -> Bool {
            tab != earlier.tab
                || paths != earlier.paths
                || videoID != earlier.videoID
                || (isPlayerExpanded && !earlier.isPlayerExpanded)
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
            openVideoLink(id: id, startSeconds: startSeconds, playlistID: nil)
        case .videoInPlaylist(let id, let startSeconds, let playlistID):
            openVideoLink(id: id, startSeconds: startSeconds, playlistID: playlistID)
        case .channel(let id):
            show(.channel(id: id))
        case .playlist(let id):
            show(.playlist(id: id))
        case .search(let query):
            router.showRoot(of: .search)
            show(.searchResults(query: query))
        }
    }

    /// Opens the video of a link at once. With a playlist (`list=`), the video starts alone and the playlist joins in as
    /// its queue when it has loaded (`queuePlaylist`).
    private func openVideoLink(id: String, startSeconds: Int?, playlistID: String?) {
        // YouTube's resolver hands back whatever the link said (`watch?v=abc` resolves to the video "abc"), so a
        // malformed id is caught here instead of opening a player that can only fail.
        guard Self.isVideoID(id) else {
            linkError = Self.unopenableLinkMessage
            return
        }
        open(knownSummary(forID: id) ?? VideoSummary(id: id, title: ""), startAt: startSeconds.map(Double.init))
        if let playlistID {
            queuePlaylist(playlistID, behind: id)
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
