import Foundation

/// YouTube's own Home, read as the TV app. It tries the recipes of `TVClientConfig.homeRecipes` in turn (the one that
/// worked last first) and uses the first that answers signed in with at least one video. Card handles, the recipe and
/// the last raw replies live here; the replies stay in memory and leave only scrubbed, for the diagnostics sample.
public actor RecommendationsService: RecommendationsProviding {
    static let recipeKey = "noslop.tvHomeRecipe"
    private static let keptReplies = 3

    /// Where a continuation token came from: the recipe's host and the visitorData of the first reply.
    private struct Session {
        let recipe: TVHomeRecipe
        let visitorData: String?
    }

    private let client: TVClient
    private let language: String
    private let region: String
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    private var remembered: TVHomeRecipe?
    private var handles: [String: TVCardHandle] = [:]
    private var sessions: [String: Session] = [:]
    private var recentReplies: [JSON] = []
    private var lastHome: HomeLoadReport?
    /// Bumped by `clearAccountData`; a load that started before a clear must not write its results afterwards.
    private var epoch = 0
    /// Filled by the card actions (Task 7).
    var lastCardAction: CardActionReport?

    public init(
        client: TVClient,
        language: String,
        region: String,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.language = language
        self.region = region
        self.defaults = defaults
        self.now = now
        self.remembered = Self.readRecipe(defaults)
    }

    // MARK: Home

    public func homePage(continuation: String?) async throws -> TVHomePage {
        if let continuation { return try await continuationPage(continuation) }
        return try await firstPage()
    }

    private func firstPage() async throws -> TVHomePage {
        let started = epoch
        var ladder = TVClientConfig.homeRecipes
        if let remembered, let index = ladder.firstIndex(of: remembered) {
            ladder.remove(at: index)
            ladder.insert(remembered, at: 0)
        }
        var fallback: (page: TVHomePage, parse: TVHomeParse, recipe: TVHomeRecipe, visitor: String?)?
        var lastError: (any Error)?
        var lastStatus: Int?
        var lastRecipe = ladder[0]
        for recipe in ladder {
            lastRecipe = recipe
            let reply: JSON?
            do {
                reply = try await client.post("browse", body: body(["browseId": .string(recipe.browseID)], visitorData: nil), host: recipe.host)
            } catch NoSlopError.recommendationsNotConnected {
                throw NoSlopError.recommendationsNotConnected
            } catch is CancellationError {
                throw CancellationError()
            } catch NoSlopError.cancelled {
                throw NoSlopError.cancelled
            } catch {
                lastError = error
                if case NoSlopError.http(let status) = error { lastStatus = status } else { lastStatus = nil }
                continue
            }
            guard let reply else { lastError = NoSlopError.decoding("Empty reply."); lastStatus = 200; continue }
            lastError = nil
            let parse = TVHomeParser.parse(reply)
            let visitor = reply["responseContext"]?["visitorData"]?.string
            let accepted = parse.loggedIn == true && !parse.videos.isEmpty
            let page = makePage(parse, recipe: recipe, usedYouTube: accepted)
            // Disconnected while the request was out: hand the answer back, store nothing.
            if epoch != started { return page }
            keep(reply)
            if accepted {
                remember(recipe)
                adopt(parse, recipe: recipe, visitor: visitor, replacing: true)
                lastHome = page.report
                return page
            }
            if fallback == nil { fallback = (page, parse, recipe, visitor) }
        }
        if epoch != started {
            if let fallback { return fallback.page }
            throw lastError ?? NoSlopError.network("YouTube's Home didn't load.")
        }
        if let fallback {
            // Signed out, empty or thin everywhere: hand the first answer back so the app can fall back.
            adopt(fallback.parse, recipe: fallback.recipe, visitor: fallback.visitor, replacing: true)
            lastHome = fallback.page.report
            return fallback.page
        }
        lastHome = HomeLoadReport(recipe: Self.name(lastRecipe), status: lastStatus, at: now())
        throw lastError ?? NoSlopError.network("YouTube's Home didn't load.")
    }

    private func continuationPage(_ token: String) async throws -> TVHomePage {
        let started = epoch
        let session = sessions[token] ?? Session(recipe: remembered ?? TVClientConfig.homeRecipes[0], visitorData: nil)
        let reply: JSON?
        do {
            reply = try await client.post(
                "browse",
                body: body(["continuation": .string(token)], visitorData: session.visitorData),
                host: session.recipe.host,
                visitorData: session.visitorData
            )
        } catch {
            var status: Int?
            if case NoSlopError.http(let code) = error { status = code }
            if epoch != started { throw error }
            lastHome = HomeLoadReport(recipe: Self.name(session.recipe) + " (more)", status: status, at: now())
            throw error
        }
        guard let reply else { throw NoSlopError.decoding("Empty reply.") }
        let parse = TVHomeParser.parse(reply)
        let page = makePage(parse, recipe: session.recipe, usedYouTube: !parse.videos.isEmpty, suffix: " (more)")
        if epoch != started { return page }
        keep(reply)
        adopt(parse, recipe: session.recipe, visitor: session.visitorData, replacing: false)
        lastHome = page.report
        return page
    }

    private func body(_ extra: [String: JSON], visitorData: String?) -> JSON {
        var object = extra
        object["context"] = TVClientConfig.context(.tv, visitorData: visitorData, language: language, region: region)
        return .object(object)
    }

    private func makePage(_ parse: TVHomeParse, recipe: TVHomeRecipe, usedYouTube: Bool, suffix: String = "") -> TVHomePage {
        let ids = Set(parse.videos.map(\.id))
        let report = HomeLoadReport(
            recipe: Self.name(recipe) + suffix,
            status: 200,
            loggedIn: parse.loggedIn,
            videos: parse.videos.count,
            shorts: parse.shorts,
            skipped: parse.skipped,
            unknown: parse.unknown,
            usedYouTube: usedYouTube,
            at: now()
        )
        return TVHomePage(
            loggedIn: parse.loggedIn,
            videos: parse.videos,
            cardIDs: Set(parse.handles.keys).intersection(ids),
            continuation: parse.sectionContinuation,
            report: report
        )
    }

    /// Keeps the handles and the continuation's origin of a page the app may use.
    private func adopt(_ parse: TVHomeParse, recipe: TVHomeRecipe, visitor: String?, replacing: Bool) {
        if replacing { sessions.removeAll() }
        for (id, handle) in parse.handles { handles[id] = handle }
        if let token = parse.sectionContinuation {
            sessions[token] = Session(recipe: recipe, visitorData: visitor)
        }
    }

    private func keep(_ reply: JSON) {
        recentReplies.append(reply)
        if recentReplies.count > Self.keptReplies { recentReplies.removeFirst(recentReplies.count - Self.keptReplies) }
    }

    // MARK: Recipe memory

    private func remember(_ recipe: TVHomeRecipe) {
        remembered = recipe
        defaults.set("\(recipe.browseID)|\(recipe.host)", forKey: Self.recipeKey)
    }

    private static func readRecipe(_ defaults: UserDefaults) -> TVHomeRecipe? {
        guard let text = defaults.string(forKey: recipeKey) else { return nil }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let recipe = TVHomeRecipe(browseID: parts[0], host: parts[1])
        return TVClientConfig.homeRecipes.contains(recipe) ? recipe : nil
    }

    static func name(_ recipe: TVHomeRecipe) -> String { "\(recipe.browseID)@\(recipe.host)" }

    // MARK: Card actions

    public func notInterested(videoID: String) async throws {
        let started = epoch
        let (token, _, status) = try await panelToken(videoID: videoID, kind: "notInterested", started: started) { $0.notInterested }
        guard let token else {
            record("notInterested", status: status, accepted: false, started: started)
            throw NoSlopError.unavailable(reason: Self.notOffered)
        }
        _ = try await sendFeedback(token, kind: "notInterested", started: started)
    }

    public func dontRecommendChannel(videoID: String, channelID: String?, channelName: String) async throws -> Bool {
        let started = epoch
        let (token, findings, status) = try await panelToken(videoID: videoID, kind: "dontRecommendChannel", started: started) { $0.dontRecommend }
        let sameChannel: Bool
        if let channelID, !channelID.isEmpty {
            sameChannel = findings.channelID == channelID
        } else if let panelName = findings.channelName {
            let wanted = ContentFilter.foldName(channelName)
            sameChannel = !wanted.isEmpty && ContentFilter.foldName(panelName) == wanted
        } else {
            sameChannel = false
        }
        guard let token, sameChannel else {
            record("dontRecommendChannel", status: status, accepted: false, started: started)
            return false
        }
        return try await sendFeedback(token, kind: "dontRecommendChannel", started: started)
    }

    private static let notOffered = "YouTube didn't offer this for that video."

    /// Asks YouTube for the card's menu and picks the token of one action. Nothing is sent for an ambiguous menu.
    private func panelToken(
        videoID: String, kind: String, started: Int, pick: (TVPanelFindings) -> String?
    ) async throws -> (token: String?, findings: TVPanelFindings, status: Int?) {
        guard let handle = handles[videoID] else { throw NoSlopError.unavailable(reason: Self.notOffered) }
        let reply: JSON?
        do {
            reply = try await client.post(
                "get_panel",
                body: [
                    "context": TVClientConfig.context(.tv, visitorData: nil, language: language, region: region),
                    "panelId": .string(handle.panelID),
                    "params": .string(handle.params),
                ]
            )
        } catch {
            record(kind, status: Self.status(of: error), accepted: false, started: started)
            throw error
        }
        // The account may have been disconnected (or replaced) while the menu was out.
        guard epoch == started else { throw NoSlopError.recommendationsNotConnected }
        guard let reply else {
            record(kind, status: 200, accepted: false, started: started)
            throw NoSlopError.unavailable(reason: Self.notOffered)
        }
        let findings = TVPanelParser.parse(reply)
        if findings.ambiguous {
            record(kind, status: 200, accepted: false, started: started)
            throw NoSlopError.unavailable(reason: Self.notOffered)
        }
        return (pick(findings), findings, 200)
    }

    private func sendFeedback(_ token: String, kind: String, started: Int) async throws -> Bool {
        guard epoch == started else { throw NoSlopError.recommendationsNotConnected }
        do {
            let reply = try await client.post(
                "feedback",
                body: [
                    "context": TVClientConfig.context(.tv, visitorData: nil, language: language, region: region),
                    "feedbackTokens": [.string(token)],
                ]
            )
            // Accepted needs a JSON reply without an error and no feedback marked unprocessed (as the probe judges it).
            var flags: [Bool] = []
            if let responses = reply?["feedbackResponses"]?.array {
                flags = responses.compactMap { $0["isProcessed"]?.bool }
            }
            let accepted = reply != nil && reply?["error"] == nil && flags.allSatisfy { $0 }
            record(kind, status: 200, accepted: accepted, started: started)
            return accepted
        } catch {
            record(kind, status: Self.status(of: error), accepted: false, started: started)
            throw error
        }
    }

    private static func status(of error: any Error) -> Int? {
        if case NoSlopError.http(let code) = error { return code }
        return nil
    }

    /// Stores the report unless the account data was cleared while the request was out.
    private func record(_ kind: String, status: Int?, accepted: Bool, started: Int) {
        guard epoch == started else { return }
        lastCardAction = CardActionReport(kind: kind, status: status, accepted: accepted, at: now())
    }

    func handle(for videoID: String) -> TVCardHandle? { handles[videoID] }
    func hasHandle(for videoID: String) -> Bool { handles[videoID] != nil }

    // MARK: Diagnostics

    public func diagnostics() async -> RecommendationsDiagnostics {
        RecommendationsDiagnostics(lastHome: lastHome, lastCardAction: lastCardAction)
    }

    public func diagnosticsSample() async -> JSON {
        [
            "recentHomeReplies": .array(recentReplies.map { TVScrubber.scrub($0, hideTitles: true) }),
            "rememberedRecipe": remembered.map { JSON.string(Self.name($0)) } ?? .null,
        ]
    }

    public func clearAccountData() async {
        epoch += 1
        handles.removeAll()
        sessions.removeAll()
        recentReplies.removeAll()
        lastHome = nil
        lastCardAction = nil
    }
}
