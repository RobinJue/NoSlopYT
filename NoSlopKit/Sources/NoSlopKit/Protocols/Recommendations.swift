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
    /// Seconds until the access token expires; nil when not connected.
    func secondsLeft() async -> Int?
    /// Revokes the grant (best effort) and clears the stored credentials whatever the servers answer.
    /// - Returns: whether a revoke endpoint answered 200.
    func disconnect() async -> Bool
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

    public init(id: UUID, videoID: String, lengthSeconds: Double) {
        self.id = id
        self.videoID = videoID
        self.lengthSeconds = lengthSeconds
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
}
