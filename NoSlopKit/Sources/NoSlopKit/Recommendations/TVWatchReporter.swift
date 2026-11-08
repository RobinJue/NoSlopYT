import Foundation

/// Tells YouTube, as the connected TV account, what was watched: a signed `player` request for tracking values, then the
/// playback and watchtime pings (a port of the probe's `tvprobe/report.py`).
///
/// Playback never waits for this actor: the player hooks start a low-priority task per event. Nothing here is logged, and
/// no tracking value leaves the actor except inside the pings.
public actor TVWatchReporter: WatchReporting {
    /// Refusals in a row (not OK, missing values or a refused ping) after which reporting pauses until the next launch.
    static let refusalsBeforePause = 3
    static let stsLifetime: TimeInterval = 3600
    /// The probe fetches the page as Safari does; the signature timestamp is the same for every browser.
    static let homepageUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private struct Tracking {
        var playbackURL: URL
        var watchtimeURL: URL
        var cpn: String
        var docid: String
        var length: Double
        /// The end of the range YouTube has been told about (`et` of the last watchtime ping).
        var lastEnd: Double
    }

    private enum Mint {
        case ready(Tracking, statuses: [Int])
        /// YouTube said no (or the reply lacked its tracking values).
        case refused(playerStatus: String?, ei: Bool, vm: Bool, of: Bool, statuses: [Int])
        /// No answer (offline, timeout) or not connected: try again later.
        case unreachable
    }

    private struct Session {
        let entryID: UUID
        var tracking: Tracking?
        var pendingEnd: (position: Double, finished: Bool)?
        /// The first report is on its way; false once it failed or is held back by a pause (the queue entry is the record).
        var reportInFlight = true
    }

    private let client: TVClient
    private let http: any HTTPClient
    private let queue: PendingWatchReports
    private let isEnabled: @Sendable () async -> Bool
    private let now: @Sendable () -> Date

    private var sessions: [UUID: Session] = [:]
    private var refusals = 0
    private var paused = false
    private var lastOutcome: WatchReportOutcome?
    private var sts: (value: Int, fetchedAt: Date)?
    private var replaying = false
    /// Bumped by `clearAccountData`, so work that was in flight when the account went away drops its result.
    private var generation = 0

    public init(
        client: TVClient, http: any HTTPClient, queue: PendingWatchReports,
        isEnabled: @escaping @Sendable () async -> Bool, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.http = http
        self.queue = queue
        self.isEnabled = isEnabled
        self.now = now
    }

    /// The reporter the app uses: its own cookie-free session for the pings and the page fetch, and the pending queue in
    /// `fileURL`.
    public static func live(
        tokens: any TVTokenProviding, fileURL: URL, isEnabled: @escaping @Sendable () async -> Bool
    ) -> TVWatchReporter {
        let http = URLSessionHTTPClient.isolated()
        return TVWatchReporter(
            client: TVClient(http: http, tokens: tokens), http: http,
            queue: PendingWatchReports(fileURL: fileURL), isEnabled: isEnabled
        )
    }

    // MARK: WatchReporting

    public func record(_ event: WatchEvent, for viewing: WatchViewing) async {
        guard await isEnabled() else { return }
        switch event {
        case .qualified(let position):
            await qualified(position: position, viewing: viewing)
        case .progress(let position):
            guard var tracking = sessions[viewing.id]?.tracking else { return }
            let generation = generation
            if await sendRange(&tracking, to: position, final: false, generation: generation) {
                sessions[viewing.id]?.tracking = tracking
            }
        case .ended(let position, let finished):
            await ended(position: position, finished: finished, viewing: viewing)
        }
    }

    public func replayPending() async {
        guard !replaying, !paused, await isEnabled() else { return }
        replaying = true
        defer { replaying = false }
        let generation = generation
        let active = Set(sessions.values.filter(\.reportInFlight).map(\.entryID))
        for entry in queue.all() where !active.contains(entry.id) {
            guard !paused, generation == self.generation, await isEnabled() else { return }
            switch await mint(videoID: entry.videoID, length: entry.lengthSeconds, position: entry.position, generation: generation) {
            case .ready(var tracking, let statuses):
                guard generation == self.generation else { return }
                var all = statuses
                if entry.finished {
                    _ = await sendFinal(&tracking, at: entry.position, statuses: &all, generation: generation)
                }
                guard generation == self.generation else { return }
                if all.allSatisfy({ (200..<300).contains($0) }) {
                    queue.remove(id: entry.id)
                    succeeded(statuses: all)
                } else {
                    queue.remove(id: entry.id)
                    refused(playerStatus: "OK", ei: true, vm: true, of: true, statuses: all)
                }
            case .refused(let playerStatus, let ei, let vm, let of, let statuses):
                guard generation == self.generation else { return }
                queue.remove(id: entry.id)
                refused(playerStatus: playerStatus, ei: ei, vm: vm, of: of, statuses: statuses)
            case .unreachable:
                lastOutcome = WatchReportOutcome(status: "waiting", at: now())
                return
            }
        }
    }

    public func outcome() async -> WatchReportOutcome? { lastOutcome }

    public func isPaused() async -> Bool { paused }

    public func clearAccountData() async {
        generation += 1
        sessions = [:]
        queue.removeAll()
        lastOutcome = nil
        refusals = 0
        paused = false
        sts = nil
    }

    // MARK: Events

    private func qualified(position: Double, viewing: WatchViewing) async {
        guard sessions[viewing.id] == nil else { return }
        // Written first, so a crash or a lost connection still leaves the report to replay.
        let entry = PendingWatchReport(videoID: viewing.videoID, lengthSeconds: viewing.lengthSeconds, position: position, createdAt: now())
        queue.add(entry)
        sessions[viewing.id] = Session(entryID: entry.id, tracking: nil, pendingEnd: nil)
        guard !paused else { sessions[viewing.id]?.reportInFlight = false; return }
        let generation = generation

        let result = await mint(videoID: viewing.videoID, length: viewing.lengthSeconds, position: position, generation: generation)
        guard generation == self.generation else { return }
        switch result {
        case .ready(var tracking, var statuses):
            queue.remove(id: entry.id)
            sessions[viewing.id]?.tracking = tracking
            succeeded(statuses: statuses)
            // The viewing ended while the first report was on its way.
            if let end = sessions[viewing.id]?.pendingEnd {
                statuses = []
                let ok = await finish(&tracking, position: end.position, finished: end.finished, statuses: &statuses, generation: generation)
                guard generation == self.generation else { return }
                sessions[viewing.id] = nil
                if !ok && statuses.isEmpty { requeue(viewing, position: end.position, finished: end.finished) }
            }
        case .refused(let playerStatus, let ei, let vm, let of, let statuses):
            queue.remove(id: entry.id)
            sessions[viewing.id] = nil
            refused(playerStatus: playerStatus, ei: ei, vm: vm, of: of, statuses: statuses)
        case .unreachable:
            // The entry stays for `replayPending`; later events of this viewing update it.
            sessions[viewing.id]?.reportInFlight = false
            lastOutcome = WatchReportOutcome(status: "waiting", at: now())
        }
    }

    /// Puts a closing report that a lost connection cut off back into the queue, so a replay sends it.
    private func requeue(_ viewing: WatchViewing, position: Double, finished: Bool) {
        queue.add(PendingWatchReport(
            videoID: viewing.videoID, lengthSeconds: viewing.lengthSeconds, position: position, finished: finished, createdAt: now()
        ))
    }

    private func ended(position: Double, finished: Bool, viewing: WatchViewing) async {
        guard let session = sessions[viewing.id] else { return }
        guard var tracking = session.tracking else {
            // No tracking values (the first report is in flight, failed, or waits for a launch): the queued entry says it.
            if session.reportInFlight { sessions[viewing.id]?.pendingEnd = (position, finished) } else { sessions[viewing.id] = nil }
            if let entry = queue.all().first(where: { $0.id == session.entryID }) {
                var updated = entry
                updated.position = max(position, entry.position)
                updated.finished = finished
                queue.add(updated)
            }
            return
        }
        let generation = generation
        var statuses: [Int] = []
        let ok = await finish(&tracking, position: position, finished: finished, statuses: &statuses, generation: generation)
        guard generation == self.generation else { return }
        sessions[viewing.id] = nil
        if !ok && statuses.isEmpty { requeue(viewing, position: position, finished: finished) }
        if !statuses.isEmpty {
            if statuses.allSatisfy({ (200..<300).contains($0) }) { succeeded(statuses: statuses) } else {
                refused(playerStatus: "OK", ei: true, vm: true, of: true, statuses: statuses)
            }
        }
    }

    // MARK: Pings

    /// The closing report: the range played since the last one, then (when the video was watched to its end) the final ping.
    private func finish(_ tracking: inout Tracking, position: Double, finished: Bool, statuses: inout [Int], generation: Int) async -> Bool {
        var ok = true
        if position > tracking.lastEnd {
            ok = await watchtime(&tracking, from: tracking.lastEnd, to: position, final: false, statuses: &statuses, generation: generation)
        }
        if ok && finished {
            ok = await sendFinal(&tracking, at: position, statuses: &statuses, generation: generation)
        }
        return ok
    }

    private func sendFinal(_ tracking: inout Tracking, at position: Double, statuses: inout [Int], generation: Int) async -> Bool {
        if position > tracking.lastEnd {
            guard await watchtime(&tracking, from: tracking.lastEnd, to: position, final: false, statuses: &statuses, generation: generation) else { return false }
        }
        let end = max(position, tracking.lastEnd)
        return await watchtime(&tracking, from: end, to: end, final: true, statuses: &statuses, generation: generation)
    }

    /// A progress report: only when the position moved forward. Returns whether the ping was accepted.
    private func sendRange(_ tracking: inout Tracking, to position: Double, final: Bool, generation: Int) async -> Bool {
        guard position > tracking.lastEnd else { return false }
        var statuses: [Int] = []
        let ok = await watchtime(&tracking, from: tracking.lastEnd, to: position, final: final, statuses: &statuses, generation: generation)
        guard generation == self.generation else { return false }
        if !statuses.isEmpty {
            if statuses.allSatisfy({ (200..<300).contains($0) }) { succeeded(statuses: statuses) } else {
                refused(playerStatus: "OK", ei: true, vm: true, of: true, statuses: statuses)
            }
        }
        return ok
    }

    @discardableResult
    private func watchtime(
        _ tracking: inout Tracking, from start: Double, to end: Double, final: Bool, statuses: inout [Int], generation: Int
    ) async -> Bool {
        let url = TVTracking.pingURL(
            base: tracking.watchtimeURL, kind: .watchtime, docid: tracking.docid, length: tracking.length,
            cpn: tracking.cpn, cmt: end, st: start, et: end, final: final
        )
        guard let status = try? await client.get(url, profile: .legacy, authorized: true) else { return false }
        guard generation == self.generation else { return false }
        statuses.append(status)
        guard (200..<300).contains(status) else { return false }
        tracking.lastEnd = max(tracking.lastEnd, end)
        return true
    }

    // MARK: Minting

    /// A signed `player` request, then the playback ping and the first watchtime ping (0 to `position`).
    private func mint(videoID: String, length: Double, position: Double, generation: Int) async -> Mint {
        let signature: Int?
        do {
            signature = try await signatureTimestamp()
        } catch {
            return .unreachable
        }
        var playbackContext: [String: JSON] = ["html5Preference": "HTML5_PREF_WANTS"]
        if let signature { playbackContext["signatureTimestamp"] = .number(Double(signature)) }
        let body: JSON = [
            "context": TVClientConfig.context(.legacy, visitorData: nil, language: "en", region: "US"),
            "videoId": .string(videoID),
            "racyCheckOk": true,
            "contentCheckOk": true,
            "playbackContext": ["contentPlaybackContext": .object(playbackContext)],
        ]
        let reply: JSON?
        do {
            reply = try await client.post("player", body: body, profile: .legacy)
        } catch let error as NoSlopError {
            switch error {
            case .network, .cancelled, .recommendationsNotConnected: return .unreachable
            default: return .refused(playerStatus: nil, ei: false, vm: false, of: false, statuses: [])
            }
        } catch {
            return .unreachable
        }
        guard generation == self.generation else { return .unreachable }
        guard let reply else { return .refused(playerStatus: nil, ei: false, vm: false, of: false, statuses: []) }
        let values = TVTracking.values(fromPlayer: reply)
        guard values.status == "OK", let playbackURL = values.playbackURL, let watchtimeURL = values.watchtimeURL,
              values.hasEI, values.hasVM, values.hasOF else {
            return .refused(playerStatus: values.status, ei: values.hasEI, vm: values.hasVM, of: values.hasOF, statuses: [])
        }

        var tracking = Tracking(
            playbackURL: playbackURL, watchtimeURL: watchtimeURL, cpn: TVTracking.newCPN(),
            docid: videoID, length: length, lastEnd: 0
        )
        var statuses: [Int] = []
        let playback = TVTracking.pingURL(
            base: playbackURL, kind: .playback, docid: videoID, length: length, cpn: tracking.cpn,
            cmt: 0, st: nil, et: nil, final: false
        )
        do {
            statuses.append(try await client.get(playback, profile: .legacy, authorized: true))
        } catch {
            return .unreachable
        }
        guard generation == self.generation else { return .unreachable }
        guard statuses.allSatisfy({ (200..<300).contains($0) }) else {
            return .refused(playerStatus: values.status, ei: true, vm: true, of: true, statuses: statuses)
        }
        let before = statuses.count
        await watchtime(&tracking, from: 0, to: position, final: false, statuses: &statuses, generation: generation)
        guard generation == self.generation else { return .unreachable }
        if statuses.count == before { return .unreachable }
        guard statuses.allSatisfy({ (200..<300).contains($0) }) else {
            return .refused(playerStatus: values.status, ei: true, vm: true, of: true, statuses: statuses)
        }
        return .ready(tracking, statuses: statuses)
    }

    /// The page's signature timestamp, fetched anonymously and kept for an hour. A page without one gives nil and the
    /// request goes without (the probe does the same); a lost connection throws.
    private func signatureTimestamp() async throws -> Int? {
        if let sts, now().timeIntervalSince(sts.fetchedAt) < Self.stsLifetime { return sts.value }
        guard let url = URL(string: "https://www.youtube.com/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.homepageUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200,
              let value = TVTracking.signatureTimestamp(fromHomepage: String(decoding: data, as: UTF8.self)) else { return nil }
        sts = (value, now())
        return value
    }

    // MARK: Outcome

    private func succeeded(statuses: [Int]) {
        refusals = 0
        lastOutcome = WatchReportOutcome(status: "reported", playerStatus: "OK", hasEI: true, hasVM: true, hasOF: true, pingStatuses: statuses, at: now())
    }

    private func refused(playerStatus: String?, ei: Bool, vm: Bool, of: Bool, statuses: [Int]) {
        refusals += 1
        if refusals >= Self.refusalsBeforePause { paused = true }
        lastOutcome = WatchReportOutcome(status: "refused", playerStatus: playerStatus, hasEI: ei, hasVM: vm, hasOF: of, pingStatuses: statuses, at: now())
    }
}
