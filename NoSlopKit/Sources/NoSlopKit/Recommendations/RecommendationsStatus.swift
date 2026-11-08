import Foundation

// What the Diagnostics screen shows about the TV connection. Presence flags, counts and short plain words only:
// never a token, a code, visitorData, a feedback token, panel params or a tracking value.

/// What the last load of YouTube's Home did.
public struct HomeLoadReport: Codable, Sendable, Equatable {
    /// Which recipe of the ladder answered (or the last one tried).
    public var recipe: String
    public var status: Int?
    public var loggedIn: Bool?
    public var videos: Int
    public var shorts: Int
    /// Why cards were left out, by reason (ads, promos, shelves ...).
    public var skipped: [String: Int]
    /// Card kinds the parser did not recognise, by name.
    public var unknown: [String: Int]
    /// Whether YouTube's Home was shown (false: the on-device mix took over).
    public var usedYouTube: Bool
    public var at: Date

    public init(
        recipe: String, status: Int? = nil, loggedIn: Bool? = nil, videos: Int = 0, shorts: Int = 0,
        skipped: [String: Int] = [:], unknown: [String: Int] = [:], usedYouTube: Bool = false, at: Date
    ) {
        self.recipe = recipe
        self.status = status
        self.loggedIn = loggedIn
        self.videos = videos
        self.shorts = shorts
        self.skipped = skipped
        self.unknown = unknown
        self.usedYouTube = usedYouTube
        self.at = at
    }
}

/// What the last "Not interested" or "Don't recommend channel" did.
public struct CardActionReport: Codable, Sendable, Equatable {
    public var kind: String
    public var status: Int?
    public var accepted: Bool
    public var at: Date

    public init(kind: String, status: Int? = nil, accepted: Bool, at: Date) {
        self.kind = kind
        self.status = status
        self.accepted = accepted
        self.at = at
    }
}

/// What the last watch report did.
public struct WatchReportOutcome: Codable, Sendable, Equatable {
    public var status: String
    public var playerStatus: String?
    public var hasEI: Bool
    public var hasVM: Bool
    public var hasOF: Bool
    public var pingStatuses: [Int]
    public var at: Date

    public init(
        status: String, playerStatus: String? = nil, hasEI: Bool = false, hasVM: Bool = false, hasOF: Bool = false,
        pingStatuses: [Int] = [], at: Date
    ) {
        self.status = status
        self.playerStatus = playerStatus
        self.hasEI = hasEI
        self.hasVM = hasVM
        self.hasOF = hasOF
        self.pingStatuses = pingStatuses
        self.at = at
    }
}

/// Everything the Diagnostics screen lists.
public struct RecommendationsDiagnostics: Codable, Sendable, Equatable {
    public var lastHome: HomeLoadReport?
    public var lastCardAction: CardActionReport?
    public var lastReport: WatchReportOutcome?
    public var pausedReporting: Bool
    public var tokenSecondsLeft: Int?

    public init(
        lastHome: HomeLoadReport? = nil, lastCardAction: CardActionReport? = nil, lastReport: WatchReportOutcome? = nil,
        pausedReporting: Bool = false, tokenSecondsLeft: Int? = nil
    ) {
        self.lastHome = lastHome
        self.lastCardAction = lastCardAction
        self.lastReport = lastReport
        self.pausedReporting = pausedReporting
        self.tokenSecondsLeft = tokenSecondsLeft
    }
}
