import Foundation

// The seams of the optional YouTube recommendations connection (YouTube's TV sign-in). The Google (Data API) sign-in has
// its own seam in `Services.swift`; the two are separate and neither changes the other.

/// The account behind the TV connection, as far as it is known.
public struct TVAccount: Sendable, Equatable {
    /// The account's name when YouTube told it (best effort), else nil.
    public let name: String?
    public let connectedAt: Date

    public init(name: String?, connectedAt: Date) {
        self.name = name
        self.connectedAt = connectedAt
    }
}

/// What the viewer needs to approve the sign-in on another page. The device code stays inside the auth service.
public struct TVSignInPrompt: Sendable {
    /// The code to type on the page, as the server wrote it ("ABC-DEF-GHI").
    public let userCode: String
    /// The page to open, with the code already in it.
    public let verificationURL: URL
    public let expiresAt: Date

    public init(userCode: String, verificationURL: URL, expiresAt: Date) {
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
    }
}

/// The TV connection: sign in with a code, hand out tokens, disconnect. Conforms to `TVTokenProviding`, so `TVClient`
/// can ask it for every request.
public protocol RecommendationsAuthProviding: TVTokenProviding {
    /// The connected account from the Keychain, without any network traffic; nil when not connected.
    func currentAccount() async -> TVAccount?
    func beginSignIn() async throws -> TVSignInPrompt
    /// Waits until the viewer has approved the code (polling), then stores the tokens. Honours cancellation.
    func completeSignIn(_ prompt: TVSignInPrompt) async throws -> TVAccount
    /// The app is back from Google's page: asks for the approval now if the sign-in is only waiting for its next poll. Never
    /// cancels a request that is already on its way (its answer can be the one-time approval).
    func pollSoon() async
    /// Seconds until the access token expires; nil when not connected.
    func secondsLeft() async -> Int?
    /// Clears the stored credentials first, then revokes the grant (best effort).
    func disconnect() async -> TVDisconnectResult
    /// Tells `handler` when the grant ended on its own (Google refused to renew it: the access was removed, the password
    /// changed, or the token expired from disuse) and the stored credentials were cleared.
    func onGrantEnded(_ handler: @escaping @Sendable () async -> Void) async
}

public extension RecommendationsAuthProviding {
    func onGrantEnded(_ handler: @escaping @Sendable () async -> Void) async {}
    func pollSoon() async {}
}

/// What a disconnect achieved.
public struct TVDisconnectResult: Sendable, Equatable {
    /// Whether a revoke endpoint answered 200, so Google ended the access too.
    public var revoked: Bool
    /// Whether the stored credentials are gone from this device.
    public var clearedLocally: Bool

    public init(revoked: Bool, clearedLocally: Bool = true) {
        self.revoked = revoked
        self.clearedLocally = clearedLocally
    }
}

// MARK: - Home and reporting

/// One page of YouTube's own Home, already reduced to videos the app may show.
public struct TVHomePage: Sendable {
    /// Whether YouTube treated the request as signed in; nil when the reply did not say.
    public var loggedIn: Bool?
    public var videos: [VideoSummary]
    /// The ids of the videos that came from YouTube's Home cards (they get the card actions).
    public var cardIDs: Set<String>
    public var continuation: String?
    public var report: HomeLoadReport

    public init(loggedIn: Bool? = nil, videos: [VideoSummary] = [], cardIDs: Set<String> = [], continuation: String? = nil, report: HomeLoadReport) {
        self.loggedIn = loggedIn
        self.videos = videos
        self.cardIDs = cardIDs
        self.continuation = continuation
        self.report = report
    }
}

/// YouTube's Home and the actions on its cards.
public protocol RecommendationsProviding: Sendable {
    func homePage(continuation: String?) async throws -> TVHomePage
    func notInterested(videoID: String) async throws
    /// - Returns: whether YouTube accepted it.
    func dontRecommendChannel(videoID: String, channelID: String?, channelName: String) async throws -> Bool
    func diagnostics() async -> RecommendationsDiagnostics
    /// A scrubbed JSON picture for the "Save diagnostics" button: presence flags and counts only.
    func diagnosticsSample() async -> JSON
    /// Forgets card handles and the cached Home (on disconnect).
    func clearAccountData() async
}

/// One viewing of one video: reports for it are made once.
public struct WatchViewing: Sendable, Hashable {
    public let id: UUID
    public let videoID: String
    public let lengthSeconds: Double
    /// Where the media time that the event reports began (a resume at 10:00 starts there, a seek starts a new range);
    /// nil when the sender does not know, and the reporter goes on from the end of the last report.
    public let rangeStart: Double?

    public init(id: UUID, videoID: String, lengthSeconds: Double, rangeStart: Double? = nil) {
        self.id = id
        self.videoID = videoID
        self.lengthSeconds = lengthSeconds
        self.rangeStart = rangeStart
    }

    /// The same viewing, with the start of the range that the next event reports.
    public func starting(at rangeStart: Double?) -> WatchViewing {
        WatchViewing(id: id, videoID: videoID, lengthSeconds: lengthSeconds, rangeStart: rangeStart)
    }
}

public enum WatchEvent: Sendable {
    case qualified(position: Double)
    case progress(position: Double)
    case ended(position: Double, finished: Bool)
}

/// Tells YouTube what was watched. Never awaited by playback.
public protocol WatchReporting: Sendable {
    func record(_ event: WatchEvent, for viewing: WatchViewing) async
    func replayPending() async
    func outcome() async -> WatchReportOutcome?
    func isPaused() async -> Bool
    /// Drops pending reports and state (on disconnect).
    func clearAccountData() async
    /// The owner turned sending off: the queued reports and the viewings in progress are dropped, so nothing about them
    /// is sent when it is turned on again.
    func sharingTurnedOff() async
}

/// Part A placeholder for `live()` until the Home service replaces it: nothing is connected.
public struct UnavailableRecommendations: RecommendationsProviding {
    public init() {}

    public func homePage(continuation: String?) async throws -> TVHomePage { throw NoSlopError.recommendationsNotConnected }
    public func notInterested(videoID: String) async throws { throw NoSlopError.recommendationsNotConnected }
    public func dontRecommendChannel(videoID: String, channelID: String?, channelName: String) async throws -> Bool {
        throw NoSlopError.recommendationsNotConnected
    }
    public func diagnostics() async -> RecommendationsDiagnostics { RecommendationsDiagnostics() }
    public func diagnosticsSample() async -> JSON { [:] }
    public func clearAccountData() async {}
}

/// Part A placeholder for `live()` until the reporter replaces it: does nothing.
public struct NoWatchReporter: WatchReporting {
    public init() {}

    public func record(_ event: WatchEvent, for viewing: WatchViewing) async {}
    public func replayPending() async {}
    public func outcome() async -> WatchReportOutcome? { nil }
    public func isPaused() async -> Bool { false }
    public func clearAccountData() async {}
    public func sharingTurnedOff() async {}
}
