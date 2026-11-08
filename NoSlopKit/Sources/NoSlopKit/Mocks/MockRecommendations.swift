import Foundation
import OSLog

// Mocks of the YouTube recommendations connection, for previews and `-mockServices YES` launches.

/// `RecommendationsAuthProviding` without a network: the code is always `MOCK-CODE` and the approval "arrives" after
/// `delay`.
public actor MockRecommendationsAuth: RecommendationsAuthProviding {
    private var account: TVAccount?
    private let delay: Duration

    public init(connected: Bool = false, delay: Duration = .seconds(2)) {
        self.delay = delay
        self.account = connected ? TVAccount(name: "Mock Account", connectedAt: Date()) : nil
    }

    public func currentAccount() async -> TVAccount? { account }

    public func beginSignIn() async throws -> TVSignInPrompt {
        guard let url = URL(string: "https://www.google.com/device?user_code=MOCK-CODE") else { throw NoSlopError.recommendationsNotConnected }
        return TVSignInPrompt(userCode: "MOCK-CODE", verificationURL: url, expiresAt: Date().addingTimeInterval(1800))
    }

    public func completeSignIn(_ prompt: TVSignInPrompt) async throws -> TVAccount {
        do {
            try await Task.sleep(for: delay)
        } catch {
            throw CancellationError()
        }
        let connected = TVAccount(name: "Mock Account", connectedAt: Date())
        account = connected
        return connected
    }

    public func secondsLeft() async -> Int? { account == nil ? nil : 3000 }

    public func disconnect() async -> Bool {
        account = nil
        return true
    }

    public func accessToken() async throws -> String {
        guard account != nil else { throw NoSlopError.recommendationsNotConnected }
        return "mock"
    }

    public func refreshAfterUnauthorized() async throws -> String { try await accessToken() }
}

/// YouTube's Home over `SampleData`, with the cards the real parser must keep out of a normal feed.
public actor MockRecommendations: RecommendationsProviding {
    /// A card action as the mock saw it.
    public struct Action: Sendable, Equatable {
        public let kind: String
        public let videoID: String
        public let channelID: String?

        public init(kind: String, videoID: String, channelID: String?) {
            self.kind = kind
            self.videoID = videoID
            self.channelID = channelID
        }
    }

    public private(set) var recordedActions: [Action] = []
    private var lastHome: HomeLoadReport?
    private var lastCardAction: CardActionReport?
    private let delay: Duration

    public init(delay: Duration = .milliseconds(300)) {
        self.delay = delay
    }

    private static let pageTwoToken = "mock-recommendations:2"

    private static let blockedExample = ChannelRef(id: "UCblockedexample0000000", name: "Blocked Example")

    /// The four videos that exercise the filters: a Short, a members-only video, a live stream and a video of a
    /// channel that a test blocks by name.
    private static func specialVideos() -> [VideoSummary] {
        func make(_ id: String, _ title: String, channel: ChannelRef, short: Bool = false, members: Bool = false, live: Bool = false) -> VideoSummary {
            VideoSummary(
                id: id, title: title, channel: channel, thumbnails: VideoSummary.defaultThumbnails(for: id),
                durationSeconds: live || short ? nil : 600, viewCount: 1_000, viewCountText: "1,000 views",
                publishedText: "1 day ago", isLive: live, isShort: short, isMembersOnly: members
            )
        }
        let other = SampleData.blender.ref
        return [
            make("mockShort0001", "A Short from YouTube's Home", channel: other, short: true),
            make("mockMember001", "Members only, from YouTube's Home", channel: other, members: true),
            make("mockLive00001", "Live now, from YouTube's Home", channel: other, live: true),
            make("mockBlocked01", "A video of a channel you may block", channel: blockedExample),
        ]
    }

    public func homePage(continuation: String?) async throws -> TVHomePage {
        do {
            try await Task.sleep(for: delay)
        } catch {
            throw NoSlopError.cancelled
        }
        let second = continuation == Self.pageTwoToken
        let videos: [VideoSummary]
        if second {
            videos = Array(SampleData.videos.filter { !$0.isShort }.dropFirst(8))
        } else {
            videos = Array(SampleData.videos.filter { !$0.isShort }.prefix(8)) + Self.specialVideos()
        }
        let report = HomeLoadReport(
            recipe: "mock", status: 200, loggedIn: true, videos: videos.count, shorts: videos.filter(\.isShort).count,
            usedYouTube: true, at: Date()
        )
        lastHome = report
        return TVHomePage(
            loggedIn: true, videos: videos, cardIDs: Set(videos.map(\.id)),
            continuation: second ? nil : Self.pageTwoToken, report: report
        )
    }

    public func notInterested(videoID: String) async throws {
        recordedActions.append(Action(kind: "notInterested", videoID: videoID, channelID: nil))
        lastCardAction = CardActionReport(kind: "notInterested", status: 200, accepted: true, at: Date())
    }

    public func dontRecommendChannel(videoID: String, channelID: String?, channelName: String) async throws -> Bool {
        recordedActions.append(Action(kind: "dontRecommendChannel", videoID: videoID, channelID: channelID))
        lastCardAction = CardActionReport(kind: "dontRecommendChannel", status: 200, accepted: true, at: Date())
        return true
    }

    public func diagnostics() async -> RecommendationsDiagnostics {
        RecommendationsDiagnostics(lastHome: lastHome, lastCardAction: lastCardAction, lastReport: nil, pausedReporting: false, tokenSecondsLeft: 3000)
    }

    public func diagnosticsSample() async -> JSON {
        let d = await diagnostics()
        return [
            "mock": true,
            "homeRecipe": .string(d.lastHome?.recipe ?? "none"),
            "homeVideos": .number(Double(d.lastHome?.videos ?? 0)),
            "cardActions": .number(Double(recordedActions.count)),
            "tokenPresent": true,
        ]
    }

    public func clearAccountData() async {
        recordedActions = []
        lastHome = nil
        lastCardAction = nil
    }
}

/// A watch reporter that only remembers what it was told. It also writes each event to the log (category
/// `watchReport`, lines that start with "[watchReport]") and keeps the last one as the outcome the Diagnostics screen
/// shows, so a mock run can be checked.
public actor MockWatchReporter: WatchReporting {
    public struct Recorded: Sendable {
        public let event: WatchEvent
        public let viewing: WatchViewing
    }

    public private(set) var recordedEvents: [Recorded] = []
    private var lastOutcome: WatchReportOutcome?
    private var replays = 0
    private static let log = Logger(subsystem: "com.robinjungerich.noslopyt", category: "watchReport")

    public init() {}

    public func record(_ event: WatchEvent, for viewing: WatchViewing) async {
        recordedEvents.append(Recorded(event: event, viewing: viewing))
        let kind: String
        switch event {
        case .qualified(let position): kind = "qualified at \(Int(position)) s"
        case .progress(let position): kind = "progress at \(Int(position)) s"
        case .ended(let position, let finished): kind = "ended at \(Int(position)) s finished=\(finished)"
        }
        Self.log.info("[watchReport] video=\(viewing.videoID, privacy: .public) \(kind, privacy: .public)")
        lastOutcome = WatchReportOutcome(status: "mock: \(kind)", playerStatus: "OK", hasEI: true, hasVM: true, hasOF: true, pingStatuses: [204], at: Date())
    }

    public func replayPending() async {
        replays += 1
        Self.log.info("[watchReport] replay \(self.replays, privacy: .public)")
    }

    public func outcome() async -> WatchReportOutcome? { lastOutcome }
    public func isPaused() async -> Bool { false }
    public func clearAccountData() async {
        recordedEvents = []
        lastOutcome = nil
    }
}
