import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import NoSlopKit

// MARK: - Support shared by the download tests

/// A scratch directory of its own per test (tests run in parallel).
struct DownloadTestDirectory {
    let url: URL

    static func make() throws -> DownloadTestDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoSlopDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return DownloadTestDirectory(url: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What a `DownloadStubServer` does with a request.
enum DownloadStubReply: Sendable {
    case response(status: Int, headers: [String: String], body: Data)
    case failure(URLError.Code)
}

/// A fake googlevideo for one test. It serves byte ranges of the resources registered on it, under a host name
/// that only this instance owns, so tests running in parallel never see each other's traffic.
final class DownloadStubServer: Sendable {
    struct LoggedRequest: Sendable, Equatable {
        var path: String
        var range: ClosedRange<Int64>?
    }

    /// How a matching request is answered instead of the normal 206.
    enum Fault: Sendable {
        case status(Int)
        case network(URLError.Code)
        /// A 206 whose body is cut short by this many bytes.
        case truncated(by: Int)
        /// A 200 with the whole resource, as a server that ignores `Range` would send.
        case ignoresRange
    }

    private struct Resource {
        var data: Data?
        var length: Int64
        var filler: UInt8
    }

    private struct Rule {
        var path: String
        var rangeStart: Int64?
        var fault: Fault
        var remaining: Int?
    }

    private struct State {
        var resources: [String: Resource] = [:]
        var rules: [Rule] = []
        var requests: [LoggedRequest] = []
        var delay: TimeInterval = 0
    }

    let host: String
    private let state = Mutex(State())

    init() {
        host = "stub-\(UUID().uuidString.lowercased()).test"
        DownloadStubURLProtocol.register(self)
    }

    deinit {
        DownloadStubURLProtocol.unregister(host: host)
    }

    func url(_ path: String) -> URL {
        URL(string: "https://\(host)\(path)")!
    }

    func serve(_ path: String, data: Data) {
        state.withLock { $0.resources[path] = Resource(data: data, length: Int64(data.count), filler: 0) }
    }

    /// A resource of this many bytes that is never materialised in the test: every byte is `filler`.
    func serve(_ path: String, syntheticLength: Int64, filler: UInt8 = 0xAB) {
        state.withLock { $0.resources[path] = Resource(data: nil, length: syntheticLength, filler: filler) }
    }

    /// Answers requests for `path` (only those starting at `rangeStart`, when given) with `fault`, `times` times
    /// (forever when nil).
    func fail(_ path: String, rangeStart: Int64? = nil, with fault: Fault, times: Int? = nil) {
        state.withLock { $0.rules.append(Rule(path: path, rangeStart: rangeStart, fault: fault, remaining: times)) }
    }

    func clearFaults() {
        state.withLock { $0.rules.removeAll() }
    }

    /// Every response is held back this long (so tests can act while a download is in flight).
    func setDelay(_ seconds: TimeInterval) {
        state.withLock { $0.delay = seconds }
    }

    var requests: [LoggedRequest] { state.withLock { $0.requests } }

    func requestCount(path: String) -> Int {
        requests.filter { $0.path == path }.count
    }

    func reply(to request: URLRequest) -> (reply: DownloadStubReply, delay: TimeInterval) {
        guard let url = request.url else { return (.failure(.badURL), 0) }
        let path = url.path
        let range = Self.parseRange(request.value(forHTTPHeaderField: "Range"))

        return state.withLock { state in
            state.requests.append(LoggedRequest(path: path, range: range))
            let delay = state.delay
            guard let resource = state.resources[path] else {
                return (.response(status: 404, headers: [:], body: Data()), delay)
            }

            var fault: Fault?
            for index in state.rules.indices where state.rules[index].path == path {
                let rule = state.rules[index]
                if let start = rule.rangeStart, start != range?.lowerBound { continue }
                if let remaining = rule.remaining {
                    if remaining <= 0 { continue }
                    state.rules[index].remaining = remaining - 1
                }
                fault = rule.fault
                break
            }

            if case .network(let code)? = fault { return (.failure(code), delay) }
            if case .status(let status)? = fault { return (.response(status: status, headers: [:], body: Data("denied".utf8)), delay) }

            let total = resource.length
            func bytes(_ slice: ClosedRange<Int64>) -> Data {
                if let data = resource.data {
                    return data.subdata(in: Int(slice.lowerBound)..<Int(slice.upperBound + 1))
                }
                return Data(repeating: resource.filler, count: Int(slice.upperBound - slice.lowerBound + 1))
            }

            let ignoresRange: Bool = {
                if case .ignoresRange? = fault { return true }
                return false
            }()
            guard let range, !ignoresRange else {
                return (.response(status: 200, headers: ["Content-Length": String(total)], body: bytes(0...(total - 1))), delay)
            }
            let clamped = range.lowerBound...min(range.upperBound, total - 1)
            var body = bytes(clamped)
            if case .truncated(let cut)? = fault { body = body.prefix(max(0, body.count - cut)) }
            let headers = [
                "Content-Range": "bytes \(clamped.lowerBound)-\(clamped.upperBound)/\(total)",
                "Content-Length": String(clamped.upperBound - clamped.lowerBound + 1),
            ]
            return (.response(status: 206, headers: headers, body: body), delay)
        }
    }

    private static func parseRange(_ header: String?) -> ClosedRange<Int64>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let lower = Int64(parts[0]), let upper = Int64(parts[1]), lower <= upper else { return nil }
        return lower...upper
    }
}

/// Routes URLSession traffic to the `DownloadStubServer` that owns the request's host.
final class DownloadStubURLProtocol: URLProtocol {
    private struct WeakServer: Sendable {
        weak var server: DownloadStubServer?
    }

    private static let servers = Mutex<[String: WeakServer]>([:])

    static func register(_ server: DownloadStubServer) {
        servers.withLock { $0[server.host] = WeakServer(server: server) }
    }

    static func unregister(host: String) {
        servers.withLock { _ = $0.removeValue(forKey: host) }
    }

    private static func server(forHost host: String?) -> DownloadStubServer? {
        guard let host else { return nil }
        return servers.withLock { $0[host]?.server }
    }

    private let stopped = Mutex(false)

    override class func canInit(with request: URLRequest) -> Bool {
        server(forHost: request.url?.host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let server = Self.server(forHost: url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (reply, delay) = server.reply(to: request)
        nonisolated(unsafe) let this = self
        let deliver: @Sendable () -> Void = {
            if this.stopped.withLock({ $0 }) { return }
            switch reply {
            case .failure(let code):
                this.client?.urlProtocol(this, didFailWithError: URLError(code))
            case .response(let status, let headers, let body):
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                    this.client?.urlProtocol(this, didFailWithError: URLError(.badServerResponse))
                    return
                }
                this.client?.urlProtocol(this, didReceive: response, cacheStoragePolicy: .notAllowed)
                this.client?.urlProtocol(this, didLoad: body)
                this.client?.urlProtocolDidFinishLoading(this)
            }
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

/// A gate a test opens from the outside. Code under test waits for it with `await opened()`, which suspends instead of
/// holding a thread: a closure that spins on `isOpen` with `Thread.sleep` keeps one thread of Swift's cooperative pool
/// for as long as it waits, and a full test run, where hundreds of tests share that pool, then starves.
final class DownloadTestGate: Sendable {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var isOpen: Bool { state.withLock { $0.isOpen } }

    func release() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Returns once the gate is open (at once when it already is).
    func opened() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isOpen = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiting.append(continuation)
                return false
            }
            if isOpen { continuation.resume() }
        }
    }
}

/// Counts calls made from closures that must be `Sendable`.
final class DownloadTestCounter: Sendable {
    private let count = Mutex(0)
    var value: Int { count.withLock { $0 } }
    func increment() { count.withLock { $0 += 1 } }
}

/// A `StreamResolving` whose answer is computed per call, so tests can hand out fresh (or different) URLs on retry.
final class DownloadStubResolver: StreamResolving, Sendable {
    typealias Provider = @Sendable (_ videoID: String, _ call: Int) throws -> StreamInfo
    typealias AsyncProvider = @Sendable (_ videoID: String, _ call: Int) async throws -> StreamInfo

    private let provider: AsyncProvider
    private let calls = Mutex(0)

    init(_ provider: @escaping Provider) {
        self.provider = { videoID, call in try provider(videoID, call) }
    }

    /// For answers that have to wait for something (`await gate.opened()`): never block a thread in here.
    init(awaiting provider: @escaping AsyncProvider) {
        self.provider = provider
    }

    var callCount: Int { calls.withLock { $0 } }

    func streamInfo(videoID: String) async throws -> StreamInfo {
        let call = calls.withLock { count -> Int in
            count += 1
            return count
        }
        return try await provider(videoID, call)
    }
}

/// "Me at the zoo": the two real fixture files (a 144p H.264 video of 18.933 s and its AAC audio).
enum ZooFixture {
    static let videoID = "jNQXAC9IVRw"
    static let summary = VideoSummary(
        id: videoID,
        title: "Me at the zoo",
        channel: ChannelRef(id: "UC4QobU6STFB0P71PMvOGN5A", name: "jawed"),
        durationSeconds: 19
    )
    static let videoBytes: Int64 = 195_278
    static let audioBytes: Int64 = 117_495
    static let itemID = "jNQXAC9IVRw-144"

    static func video(at url: URL, contentLength: Int64? = videoBytes) -> StreamFormat {
        StreamFormat(
            itag: 160, url: url, mimeType: "video/mp4; codecs=\"avc1.4D400C\"", bitrate: 82_000,
            width: 192, height: 144, fps: 15, qualityLabel: "144p",
            contentLength: contentLength, approxDurationMs: 18_933
        )
    }

    /// A 360p rendition (itag 134) next to the 144p one (itag 160). The bytes behind it are the zoo video again: the
    /// muxer only cares that they are a real H.264 MP4, not what the format claims about their size.
    static func video360(at url: URL) -> StreamFormat {
        StreamFormat(
            itag: 134, url: url, mimeType: "video/mp4; codecs=\"avc1.4D401E\"", bitrate: 120_000,
            width: 256, height: 360, fps: 15, qualityLabel: "360p",
            contentLength: videoBytes, approxDurationMs: 18_933
        )
    }

    static func audio(at url: URL, contentLength: Int64? = audioBytes) -> StreamFormat {
        StreamFormat(
            itag: 140, url: url, mimeType: "audio/mp4; codecs=\"mp4a.40.2\"", bitrate: 49_000,
            contentLength: contentLength, approxDurationMs: 19_133, audioSampleRate: 44_100
        )
    }

    static func streamInfo(formats: [StreamFormat], lengthSeconds: Int = 19, expiresIn: TimeInterval = 21_540) -> StreamInfo {
        StreamInfo(
            videoID: videoID, title: "Me at the zoo", author: "jawed", channelID: "UC4QobU6STFB0P71PMvOGN5A",
            lengthSeconds: lengthSeconds, formats: formats, expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    static func streamInfo(server: DownloadStubServer, videoPath: String = "/video.mp4", audioPath: String = "/audio.m4a") -> StreamInfo {
        streamInfo(formats: [video(at: server.url(videoPath)), audio(at: server.url(audioPath))])
    }

    static func serveFixtures(on server: DownloadStubServer) throws {
        server.serve("/video.mp4", data: try Fixture.data("zoo_video_144p.mp4"))
        server.serve("/audio.m4a", data: try Fixture.data("zoo_audio.m4a"))
    }
}

extension DownloadTuning {
    /// No waiting between chunk retries and quick progress updates.
    static let testing = DownloadTuning(retryDelay: .zero, progressInterval: 0.005)
}

/// Everything one download test needs: its own directory, fake server, resolver and manager.
@MainActor
struct DownloadHarness {
    let directory: DownloadTestDirectory
    let server: DownloadStubServer
    let resolver: DownloadStubResolver
    let manager: DownloadManager
    let root: URL
    let tuning: DownloadTuning

    /// Serves the zoo fixtures; the resolver answers every call with `provider` or, by default, the zoo formats.
    static func zoo(
        tuning: DownloadTuning = .testing,
        provider: DownloadStubResolver.Provider? = nil
    ) throws -> DownloadHarness {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        try ZooFixture.serveFixtures(on: server)
        let resolver = DownloadStubResolver(provider ?? { _, _ in ZooFixture.streamInfo(server: server) })
        return DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: tuning)
    }

    /// Like `zoo`, but the video has two renditions: 144p (itag 160, `/video.mp4`) and 360p (itag 134,
    /// `/video-360.mp4`), next to the audio. A 144p request and a 360p request pick different streams here, so they are
    /// different downloads. On the plain `zoo` video, which stops at 144p, both pick the 144p rendition and are one
    /// (see `DownloadDedupeTests`).
    static func zooWithTwoRenditions(tuning: DownloadTuning = .testing) throws -> DownloadHarness {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        try ZooFixture.serveFixtures(on: server)
        server.serve("/video-360.mp4", data: try Fixture.data("zoo_video_144p.mp4"))
        let resolver = DownloadStubResolver { _, _ in
            ZooFixture.streamInfo(formats: [
                ZooFixture.video(at: server.url("/video.mp4")),
                ZooFixture.video360(at: server.url("/video-360.mp4")),
                ZooFixture.audio(at: server.url("/audio.m4a")),
            ])
        }
        return DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: tuning)
    }

    init(directory: DownloadTestDirectory, server: DownloadStubServer, resolver: DownloadStubResolver, tuning: DownloadTuning) {
        self.directory = directory
        self.server = server
        self.resolver = resolver
        self.tuning = tuning
        self.root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        self.manager = Self.newManager(root: root, resolver: resolver, tuning: tuning)
    }

    static func newManager(root: URL, resolver: any StreamResolving, tuning: DownloadTuning) -> DownloadManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadStubURLProtocol.self]
        return DownloadManager(rootDirectory: root, streams: resolver, sessionConfiguration: configuration, tuning: tuning)
    }

    func workDirectory(for itemID: String) -> URL {
        DownloadWorkspace(root: root).directory(for: itemID)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// File names in the downloads root (hidden ones included).
    func rootListing() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    func cleanUp() {
        directory.remove()
    }
}

extension DownloadHarness {
    /// Writes what an interrupted download leaves behind: the plan, the finished parts, and a `downloads.json` that
    /// says the item was in flight.
    static func leaveInterruptedDownload(
        in root: URL,
        state: DownloadState,
        server: DownloadStubServer,
        chunkSize: Int64,
        videoChunks: Set<Int>,
        audioChunks: Set<Int>
    ) throws {
        let workspace = DownloadWorkspace(root: root)
        let video = ZooFixture.video(at: server.url("/video.mp4"))
        let audio = ZooFixture.audio(at: server.url("/audio.m4a"))
        let plan = DownloadJobPlan(
            itemID: ZooFixture.itemID, videoID: ZooFixture.videoID, title: "Me at the zoo",
            video: video, audio: audio, durationSeconds: 18.933, chunkSize: chunkSize, fileExtension: "mp4"
        )
        try FileManager.default.createDirectory(at: workspace.directory(for: ZooFixture.itemID), withIntermediateDirectories: true)
        try workspace.savePlan(plan)

        let videoData = try Fixture.data("zoo_video_144p.mp4")
        let audioData = try Fixture.data("zoo_audio.m4a")
        for (stream, data, chunks) in [(DownloadTaskDescriptor.Stream.video, videoData, videoChunks), (.audio, audioData, audioChunks)] {
            let ranges = ChunkPlanner.ranges(totalBytes: Int64(data.count), chunkSize: chunkSize)
            for index in chunks {
                let range = ranges[index]
                let part = workspace.partURL(for: DownloadTaskDescriptor(itemID: ZooFixture.itemID, stream: stream, chunkIndex: index))
                try data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1)).write(to: part)
            }
        }

        let item = DownloadItem(
            id: ZooFixture.itemID, video: ZooFixture.summary, quality: .video(maxHeight: 144), state: state,
            progress: 0.5, bytesDownloaded: 150_000, bytesTotal: ZooFixture.videoBytes + ZooFixture.audioBytes
        )
        try JSONEncoder().encode([item]).write(to: root.appendingPathComponent("downloads.json"))
    }
}

/// Polls until `condition` holds (true) or the time runs out (false).
@MainActor
func awaitDownloadCondition(timeout: Duration = .seconds(90), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// True once the item with this id has left the in-flight states.
@MainActor
func downloadIsSettled(_ manager: DownloadManager, _ id: String) -> Bool {
    guard let item = manager.items.first(where: { $0.id == id }) else { return true }
    return item.state == .completed || item.state == .failed || item.state == .paused
}

func mediaDurationAndTracks(of url: URL) async throws -> (seconds: Double, video: Int, audio: Int) {
    let asset = AVURLAsset(url: url)
    return (
        try await asset.load(.duration).seconds,
        try await asset.loadTracks(withMediaType: .video).count,
        try await asset.loadTracks(withMediaType: .audio).count
    )
}

// MARK: - DownloadManager

@MainActor
@Suite(.limitsMediaExports) struct DownloadManagerTests {
    // MARK: Options

    @Test func optionsFromStreamInfo() throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let info = StreamInfo(
            videoID: "aqz-KE-bpKQ", title: "Big Buck Bunny", author: "Blender", channelID: "UCSMOQeBJ2RAnuFungnQOxLg",
            lengthSeconds: 635, formats: BunnyDownloadFormats.all, expiresAt: .distantFuture
        )
        let options = harness.manager.availableOptions(for: info)
        #expect(options.map(\.label) == ["1080p", "720p", "480p", "360p", "Audio only"])
        let audio: Int64 = 10_271_496
        #expect(options.map(\.estimatedBytes) == [257_619_653 + audio, 150_524_867 + audio, 28_207_144 + audio, 18_294_110 + audio, audio])
        #expect(options.map(\.quality) == [.video(maxHeight: 1080), .video(maxHeight: 720), .video(maxHeight: 480), .video(maxHeight: 360), .audioOnly])
    }

    @Test func noOptionsForLiveStreamsOrWithoutFormats() throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        var live = StreamInfo(
            videoID: "x", title: "t", author: "a", channelID: "c", lengthSeconds: 0,
            isLive: true, formats: BunnyDownloadFormats.all, expiresAt: .distantFuture
        )
        #expect(harness.manager.availableOptions(for: live).isEmpty)
        live.isLive = false
        live.formats = []
        #expect(harness.manager.availableOptions(for: live).isEmpty)
    }

    // MARK: Happy path

    @Test func completesAndMuxes() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let manager = harness.manager

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(manager.items.map(\.id) == [ZooFixture.itemID])
        #expect(manager.items.first?.state == .queued)

        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        let item = try #require(manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "no message")")
        #expect(item.progress == 1)
        #expect(item.errorMessage == nil)
        #expect(item.bytesTotal == item.bytesDownloaded)

        let file = try #require(manager.fileURL(for: item))
        #expect(file.lastPathComponent == "Me at the zoo [jNQXAC9IVRw].mp4")
        #expect(item.relativeFilePath == "Me at the zoo [jNQXAC9IVRw].mp4")
        #expect(harness.exists(file))
        #expect(item.bytesTotal == Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1))
        #expect(!harness.exists(harness.workDirectory(for: ZooFixture.itemID)))

        let media = try await mediaDurationAndTracks(of: file)
        #expect(abs(media.seconds - 18.93) < 0.05, "duration \(media.seconds)")
        #expect(media.video == 1 && media.audio == 1)

        #expect(manager.completedItem(videoID: ZooFixture.videoID)?.id == ZooFixture.itemID)
        #expect(manager.bytesOnDisk == item.bytesTotal)
        #expect(harness.resolver.callCount == 1)
        #expect(harness.rootListing().filter { !$0.hasPrefix(".") }.sorted() == ["Me at the zoo [jNQXAC9IVRw].mp4", "downloads.json"])
    }

    @Test func requestsAreRangeChunks() async throws {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 100_000
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .completed)

        let video = harness.server.requests.filter { $0.path == "/video.mp4" }.compactMap(\.range).sorted { $0.lowerBound < $1.lowerBound }
        let audio = harness.server.requests.filter { $0.path == "/audio.m4a" }.compactMap(\.range).sorted { $0.lowerBound < $1.lowerBound }
        #expect(video == [0...99_999, 100_000...195_277])
        #expect(audio == [0...99_999, 100_000...117_494])
        #expect(harness.server.requests.allSatisfy { $0.range != nil }, "no plain GET of a stream: it would be throttled")
    }

    @Test func multiChunkDownloadMuxesTheSameVideo() async throws {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 40_000
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })

        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        let media = try await mediaDurationAndTracks(of: try #require(harness.manager.fileURL(for: item)))
        #expect(abs(media.seconds - 18.93) < 0.05)
        #expect(media.video == 1 && media.audio == 1)
        #expect(harness.server.requests.count == 5 + 3, "195278 bytes in 40000-byte chunks is 5, 117495 is 3")
    }

    @Test func audioOnlyDownloadIsAnM4AOfTheTrueLength() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .audioOnly)
        let id = "jNQXAC9IVRw-audio"
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, id) })

        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        let file = try #require(harness.manager.fileURL(for: item))
        #expect(file.lastPathComponent == "Me at the zoo [jNQXAC9IVRw].m4a")
        let media = try await mediaDurationAndTracks(of: file)
        #expect(abs(media.seconds - 19.13) < 0.15, "duration \(media.seconds), not the doubled 38.2")
        #expect(media.video == 0 && media.audio == 1)
        #expect(harness.server.requestCount(path: "/video.mp4") == 0, "audio-only never touches the video stream")
    }

    @Test func qualitiesOfOneVideoGetTheirOwnFiles() async throws {
        // Two renditions that really differ: qualities that resolve to the same streams are one download, and the plain
        // zoo video has only the 144p rendition, so there both would be.
        let harness = try DownloadHarness.zooWithTwoRenditions()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 360))
        #expect(harness.manager.items.map(\.id) == ["jNQXAC9IVRw-360", "jNQXAC9IVRw-144"], "newest first")
        #expect(await awaitDownloadCondition { harness.manager.items.allSatisfy { $0.state == .completed || $0.state == .failed } })

        let names = harness.manager.items.compactMap(\.relativeFilePath)
        #expect(harness.manager.items.allSatisfy { $0.state == .completed })
        #expect(names.count == 2 && Set(names).count == 2, "two qualities must not overwrite each other: \(names)")
        for item in harness.manager.items {
            #expect(harness.exists(try #require(harness.manager.fileURL(for: item))))
        }
    }

    @Test func enqueueingTheSameDownloadTwiceStartsOneJob() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(harness.manager.items.count == 1)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        // Once it is done, asking again changes nothing either.
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.manager.items.count == 1 && harness.manager.items.first?.state == .completed)
        #expect(harness.resolver.callCount == 1)
        #expect(harness.server.requests.count == 2, "one video chunk and one audio chunk, once")
    }

    @Test func progressNeverGoesBackwardsAndEndsAtOne() async throws {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 20_000
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        harness.server.setDelay(0.05)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))

        var samples: [Double] = []
        let finished = await awaitDownloadCondition {
            if let item = harness.manager.items.first {
                samples.append(item.progress)
                if item.state == .downloading { #expect(item.bytesTotal == ZooFixture.videoBytes + ZooFixture.audioBytes) }
            }
            return downloadIsSettled(harness.manager, ZooFixture.itemID)
        }
        #expect(finished)
        #expect(harness.manager.items.first?.state == .completed)
        #expect(samples.last == 1)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards: \(samples)")
        #expect(samples.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func progressAddsFinishedChunksAndTheBytesOfRunningOnes() async throws {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 100_000
        tuning.retryDelay = .seconds(60)   // the failing video chunks wait for their retry: the job stays open
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        harness.server.fail("/video.mp4", with: .network(.networkConnectionLost))
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))

        // Only the audio (117495 bytes in two chunks) is in; the total is 312773.
        let total = Double(ZooFixture.videoBytes + ZooFixture.audioBytes)
        let work = harness.workDirectory(for: ZooFixture.itemID)
        #expect(await awaitDownloadCondition {
            harness.manager.items.first?.state == .downloading
                && ["audio.0.part", "audio.1.part"].allSatisfy { FileManager.default.fileExists(atPath: work.appendingPathComponent($0).path) }
        })
        // The session's own reports of those two chunks may still be on their way; they count once, whenever they come.
        harness.manager.handle(.chunkFinished(DownloadTaskDescriptor(itemID: ZooFixture.itemID, stream: .audio, chunkIndex: 0), bytes: 100_000, inFlightBytes: 0))
        harness.manager.handle(.chunkFinished(DownloadTaskDescriptor(itemID: ZooFixture.itemID, stream: .audio, chunkIndex: 1), bytes: 17_495, inFlightBytes: 0))
        #expect(harness.manager.items.first?.bytesDownloaded == ZooFixture.audioBytes)
        #expect(abs((harness.manager.items.first?.progress ?? -1) - Double(ZooFixture.audioBytes) / total) < 0.0001)
        #expect(harness.manager.items.first?.state == .downloading)

        // A running chunk has written 50000 bytes so far.
        harness.manager.handle(.progress(itemID: ZooFixture.itemID, inFlightBytes: 50_000))
        #expect(harness.manager.items.first?.bytesDownloaded == ZooFixture.audioBytes + 50_000)
        #expect(abs((harness.manager.items.first?.progress ?? -1) - Double(ZooFixture.audioBytes + 50_000) / total) < 0.0001)

        // That chunk starting over (a retry) must not move the bar back.
        harness.manager.handle(.progress(itemID: ZooFixture.itemID, inFlightBytes: 1_000))
        #expect(harness.manager.items.first?.bytesDownloaded == ZooFixture.audioBytes + 50_000)

        // A bogus report cannot push the byte count past the total or the progress past 1.
        harness.manager.handle(.progress(itemID: ZooFixture.itemID, inFlightBytes: 10_000_000))
        #expect(harness.manager.items.first?.progress == 1)
        #expect(harness.manager.items.first?.bytesDownloaded == ZooFixture.videoBytes + ZooFixture.audioBytes)
        #expect(harness.manager.items.first?.state == .downloading)
    }

    @Test func sizeFromTheURLWhenTheFormatDoesNotSayIt() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        // contentLength is missing, but googlevideo URLs carry the size as `clen`.
        let resolver = DownloadStubResolver { _, _ in
            ZooFixture.streamInfo(formats: [
                ZooFixture.video(at: server.url("/video.mp4?clen=195278"), contentLength: nil),
                ZooFixture.audio(at: server.url("/audio.m4a?clen=117495"), contentLength: nil),
            ])
        }
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: .testing)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .completed, "\(harness.manager.items.first?.errorMessage ?? "")")
    }

    // MARK: Failures

    @Test func chunkFailureMarksFailedAndKeepsTheWork() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        // 25 MiB of video = three 10 MiB chunks; the second one is refused every time.
        server.serve("/video.mp4", syntheticLength: 26_214_400)
        server.serve("/audio.m4a", syntheticLength: 10_000)
        server.fail("/video.mp4", rangeStart: 10_485_760, with: .status(403))
        let resolver = DownloadStubResolver { _, _ in
            ZooFixture.streamInfo(formats: [
                ZooFixture.video(at: server.url("/video.mp4"), contentLength: 26_214_400),
                ZooFixture.audio(at: server.url("/audio.m4a"), contentLength: 10_000),
            ])
        }
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: .testing)
        let manager = harness.manager

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })

        let item = try #require(manager.items.first)
        #expect(item.state == .failed)
        let message = try #require(item.errorMessage)
        #expect(message.contains("403"), "the message says why: \(message)")
        #expect(item.relativeFilePath == nil)
        #expect(manager.fileURL(for: item) == nil)
        #expect(manager.completedItem(videoID: ZooFixture.videoID) == nil)
        let work = harness.workDirectory(for: ZooFixture.itemID)
        #expect(harness.exists(work.appendingPathComponent("job.json")), "the work directory stays: a retry fetches only what is missing")
        #expect(harness.rootListing().filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".m4a") }.isEmpty, "no final file")

        // A 403 means the address is dead: YouTube was asked for a new one once (the resolver is asked a second time and
        // hands out the same address, which is refused again). The failing chunk was tried with the first address, with
        // the second one, and then twice more: four times.
        #expect(resolver.callCount == 2)
        let chunkOne = server.requests.filter { $0.path == "/video.mp4" && $0.range?.lowerBound == 10_485_760 }
        #expect(chunkOne.count == 4)

        // Nothing keeps downloading after the failure and nothing comes back to life.
        let settled = server.requests.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests.count == settled)
        #expect(harness.exists(work.appendingPathComponent("job.json")))
        #expect(manager.items.first?.state == .failed)
    }

    @Test func transientFailuresAreRetriedAndTheDownloadStillCompletes() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.server.fail("/video.mp4", with: .network(.networkConnectionLost), times: 2)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        #expect(harness.server.requestCount(path: "/video.mp4") == 3)
    }

    @Test func aThirdFailureOfTheSameChunkGivesUp() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.server.fail("/video.mp4", with: .network(.networkConnectionLost), times: 3)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .failed)
        #expect(item.errorMessage == "Can't reach YouTube. Check your connection.")
        #expect(harness.server.requestCount(path: "/video.mp4") == 3)
    }

    @Test func aShortChunkIsNeverAccepted() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.server.fail("/audio.m4a", with: .truncated(by: 100))
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .failed)
        #expect(item.errorMessage == "A piece of the download arrived incomplete.")
        #expect(item.relativeFilePath == nil)
        #expect(harness.rootListing().filter { $0.hasSuffix(".mp4") }.isEmpty)
    }

    @Test func aServerThatIgnoresRangeIsRejectedForLaterChunks() async throws {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 100_000
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        // The second video chunk comes back as a 200 with the whole file instead of bytes 100000-195277.
        harness.server.fail("/video.mp4", rangeStart: 100_000, with: .ignoresRange)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .failed)
        #expect(harness.rootListing().filter { $0.hasSuffix(".mp4") }.isEmpty)
    }

    @Test func downloadedGarbageFailsTheMergeAndLeavesNoFile() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        server.serve("/video.mp4", data: Data(repeating: 0x42, count: 50_000))
        server.serve("/audio.m4a", data: Data(repeating: 0x43, count: 20_000))
        let resolver = DownloadStubResolver { _, _ in
            ZooFixture.streamInfo(formats: [
                ZooFixture.video(at: server.url("/video.mp4"), contentLength: 50_000),
                ZooFixture.audio(at: server.url("/audio.m4a"), contentLength: 20_000),
            ])
        }
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: .testing)

        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .failed, "a file that cannot be muxed is never completed")
        #expect(item.errorMessage == "Couldn't combine the video and audio.")
        #expect(item.relativeFilePath == nil)
        #expect(harness.rootListing().filter { $0.hasSuffix(".mp4") }.isEmpty)
        #expect(!harness.exists(harness.workDirectory(for: ZooFixture.itemID)))
    }

    @Test func retryReResolvesStreams() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        server.serve("/expired.mp4", data: Data(count: 10))
        server.fail("/expired.mp4", with: .status(403))
        // The first two answers have a link that has already expired (the second look-up is the one the manager makes by
        // itself when it finds the first link dead); the third one is fresh.
        let resolver = DownloadStubResolver { _, call in
            call <= 2
                ? ZooFixture.streamInfo(formats: [ZooFixture.video(at: server.url("/expired.mp4")), ZooFixture.audio(at: server.url("/audio.m4a"))])
                : ZooFixture.streamInfo(server: server)
        }
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: .testing)
        let manager = harness.manager

        manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .failed)
        #expect(resolver.callCount == 2, "a dead link is replaced once by itself; the new one was dead too")

        manager.retry(id: ZooFixture.itemID)
        #expect(manager.items.first?.state == .queued)
        #expect(manager.items.first?.errorMessage == nil)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })

        let item = try #require(manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        #expect(resolver.callCount == 3, "retry asks YouTube for fresh stream URLs")
        #expect(harness.exists(try #require(manager.fileURL(for: item))))
        #expect(manager.items.count == 1)
    }

    @Test func retryOnAnItemThatIsNotFailedOrPausedDoesNothing() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.retry(id: "nothing-here")
        #expect(harness.manager.items.isEmpty)

        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let before = harness.resolver.callCount
        harness.manager.retry(id: ZooFixture.itemID)
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.resolver.callCount == before)
        #expect(harness.manager.items.first?.state == .completed)
    }

    @Test func resolverErrorsBecomeTheMessage() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        let resolver = DownloadStubResolver { _, _ in throw NoSlopError.unplayable(reason: "This video is private.") }
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: .testing)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .failed)
        #expect(item.errorMessage == "This video is private.")
        #expect(server.requests.isEmpty)
        #expect(!harness.exists(harness.workDirectory(for: ZooFixture.itemID)))
    }

    @Test func formatsThatCannotBeDownloadedFail() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        // Only VP9 and Opus: nothing AVFoundation can mux.
        let resolver = DownloadStubResolver { _, _ in ZooFixture.streamInfo(formats: BunnyDownloadFormats.vp9 + BunnyDownloadFormats.audio.filter { $0.mimeType.contains("opus") }) }
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: .testing)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 720))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, "jNQXAC9IVRw-720") })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .failed)
        #expect(item.errorMessage == "This video has no format that can be downloaded.")
    }

    @Test func liveStreamsAreRefused() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        let resolver = DownloadStubResolver { _, _ in
            var info = ZooFixture.streamInfo(server: server)
            info.isLive = true
            return info
        }
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: .testing)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.errorMessage == "Live streams can't be downloaded.")
    }

    @Test func aStreamWithoutAKnownSizeFails() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let resolver = DownloadStubResolver { _, _ in
            ZooFixture.streamInfo(formats: [
                ZooFixture.video(at: server.url("/video.mp4"), contentLength: nil),
                ZooFixture.audio(at: server.url("/audio.m4a")),
            ])
        }
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: .testing)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .failed)
        #expect(harness.manager.items.first?.errorMessage == "Couldn't work out how big the download is.")
        #expect(server.requests.isEmpty, "nothing is fetched when the size is unknown")
    }

    // MARK: Cancel and delete

    @Test func cancelStopsTheDownloadAndRemovesTheItem() async throws {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 40_000
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        harness.server.setDelay(0.3)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { harness.manager.items.first?.state == .downloading })

        harness.manager.cancel(id: ZooFixture.itemID)
        #expect(harness.manager.items.isEmpty)
        #expect(!harness.exists(harness.workDirectory(for: ZooFixture.itemID)))

        try await Task.sleep(for: .milliseconds(800))
        #expect(harness.manager.items.isEmpty, "late chunk events must not resurrect the item")
        #expect(!harness.exists(harness.workDirectory(for: ZooFixture.itemID)))
        #expect(harness.rootListing().filter { $0.hasSuffix(".mp4") }.isEmpty)
    }

    @Test func cancelWhileResolvingStopsTheJobBeforeItStarts() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let gate = DownloadTestGate()
        let resolver = DownloadStubResolver(awaiting: { _, _ in
            await gate.opened()
            return ZooFixture.streamInfo(server: server)
        })
        let harness = DownloadHarness(directory: directory, server: server, resolver: resolver, tuning: .testing)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { resolver.callCount == 1 })
        harness.manager.cancel(id: ZooFixture.itemID)
        gate.release()

        try await Task.sleep(for: .milliseconds(400))
        #expect(harness.manager.items.isEmpty)
        #expect(server.requests.isEmpty, "nothing is downloaded for a cancelled item")
        #expect(!harness.exists(harness.workDirectory(for: ZooFixture.itemID)))
    }

    @Test func cancelDoesNotTouchFinishedDownloads() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        harness.manager.cancel(id: ZooFixture.itemID)
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed)
        #expect(harness.exists(try #require(harness.manager.fileURL(for: item))))
    }

    @Test func cancelOfAFailedItemRemovesItFromTheList() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.server.fail("/audio.m4a", with: .status(500))
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .failed)
        harness.manager.cancel(id: ZooFixture.itemID)
        #expect(harness.manager.items.isEmpty)
    }

    @Test func deleteRemovesFileAndItem() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        let file = try #require(harness.manager.fileURL(for: item))
        #expect(harness.exists(file))

        harness.manager.delete(id: ZooFixture.itemID)
        #expect(harness.manager.items.isEmpty)
        #expect(!harness.exists(file))
        #expect(harness.manager.completedItem(videoID: ZooFixture.videoID) == nil)
        #expect(harness.manager.bytesOnDisk == 0)

        // Gone for good: a new manager on the same folder does not know it either.
        let reopened = DownloadHarness.newManager(root: harness.root, resolver: harness.resolver, tuning: .testing)
        #expect(reopened.items.isEmpty)
    }

    @Test func deleteOfAnUnknownIdIsHarmless() throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.delete(id: "nope")
        harness.manager.cancel(id: "nope")
        #expect(harness.manager.items.isEmpty)
    }

    @Test func deleteWhileDownloadingStopsEverything() async throws {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 40_000
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        harness.server.setDelay(0.2)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { harness.manager.items.first?.state == .downloading })
        harness.manager.delete(id: ZooFixture.itemID)
        try await Task.sleep(for: .milliseconds(600))
        #expect(harness.manager.items.isEmpty)
        #expect(!harness.exists(harness.workDirectory(for: ZooFixture.itemID)))
        #expect(harness.rootListing().filter { $0.hasSuffix(".mp4") }.isEmpty)
    }

    @Test func deleteThenEnqueueAgainDownloadsFreshly() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        harness.manager.delete(id: ZooFixture.itemID)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        #expect(item.state == .completed)
        #expect(harness.exists(try #require(harness.manager.fileURL(for: item))))
    }

    // MARK: Persistence and relaunch

    @Test func persistsItems() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let original = try #require(harness.manager.items.first)
        #expect(original.state == .completed)

        let reopened = DownloadHarness.newManager(root: harness.root, resolver: harness.resolver, tuning: .testing)
        let restored = try #require(reopened.items.first)
        #expect(reopened.items.count == 1)
        #expect(restored.id == original.id)
        #expect(restored.state == .completed)
        #expect(restored.video == original.video)
        #expect(restored.quality == .video(maxHeight: 144))
        #expect(restored.relativeFilePath == original.relativeFilePath)
        #expect(restored.bytesTotal == original.bytesTotal)
        #expect(reopened.fileURL(for: restored) == harness.manager.fileURL(for: original))
        #expect(reopened.completedItem(videoID: ZooFixture.videoID) != nil)
        #expect(reopened.bytesOnDisk == original.bytesTotal)
    }

    @Test(arguments: [DownloadState.queued, .downloading, .merging])
    func restoredInFlightItemBecomesPaused(state: DownloadState) async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inFlight = DownloadItem(
            id: ZooFixture.itemID, video: ZooFixture.summary, quality: .video(maxHeight: 144), state: state,
            progress: 0.4, bytesDownloaded: 120_000, bytesTotal: 312_773
        )
        try JSONEncoder().encode([inFlight]).write(to: root.appendingPathComponent("downloads.json"))

        // The stub session has no tasks, as after a relaunch in which iOS dropped them.
        let resolver = DownloadStubResolver { _, _ in throw NoSlopError.network("offline") }
        let manager = DownloadHarness.newManager(root: root, resolver: resolver, tuning: .testing)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        let item = try #require(manager.items.first)
        #expect(item.id == ZooFixture.itemID && item.video == ZooFixture.summary)
        #expect(item.state == .paused)
        #expect(manager.completedItem(videoID: ZooFixture.videoID) == nil)
        #expect(resolver.callCount == 0, "restoring must not hit the network")

        // The paused state is what is on disk now, too.
        let reopened = DownloadHarness.newManager(root: root, resolver: resolver, tuning: .testing)
        #expect(reopened.items.first?.state == .paused)
    }

    @Test func settledStatesSurviveARelaunchUntouched() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let failed = DownloadItem(
            id: "aaaaaaaaaaa-720", video: VideoSummary(id: "aaaaaaaaaaa", title: "A"), quality: .video(maxHeight: 720),
            state: .failed, errorMessage: "YouTube refused the download (HTTP 403). Retry to get a fresh link."
        )
        let paused = DownloadItem(id: "bbbbbbbbbbb-audio", video: VideoSummary(id: "bbbbbbbbbbb", title: "B"), quality: .audioOnly, state: .paused)
        try JSONEncoder().encode([failed, paused]).write(to: root.appendingPathComponent("downloads.json"))

        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("offline") }, tuning: .testing)
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.items.map(\.state) == [.failed, .paused])
        #expect(manager.items.first?.errorMessage == failed.errorMessage)
    }

    @Test func aCompletedItemWhoseFileWasDeletedBecomesFailed() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        let file = try #require(harness.manager.fileURL(for: item))
        try FileManager.default.removeItem(at: file)   // the user deleted it in the Files app

        #expect(harness.manager.fileURL(for: item) == nil, "no URL for a file that is gone")
        let reopened = DownloadHarness.newManager(root: harness.root, resolver: harness.resolver, tuning: .testing)
        let restored = try #require(reopened.items.first)
        #expect(restored.state == .failed)
        #expect(restored.relativeFilePath == nil)
        #expect(restored.errorMessage == "The downloaded file is missing. Retry to download it again.")
        #expect(reopened.completedItem(videoID: ZooFixture.videoID) == nil)
        #expect(reopened.bytesOnDisk == 0)

        // Retry brings it back.
        reopened.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(reopened, ZooFixture.itemID) })
        #expect(reopened.items.first?.state == .completed)
    }

    @Test func enqueueingACompletedItemWhoseFileIsGoneDownloadsItAgain() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        let item = try #require(harness.manager.items.first)
        try FileManager.default.removeItem(at: try #require(harness.manager.fileURL(for: item)))

        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) && harness.resolver.callCount == 2 })
        let again = try #require(harness.manager.items.first)
        #expect(again.state == .completed)
        #expect(harness.exists(try #require(harness.manager.fileURL(for: again))))
    }

    @Test func aPathOutsideTheDownloadsFolderIsNeverUsed() throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = directory.url.appendingPathComponent("outside.mp4")
        try Data("not a download".utf8).write(to: outside)
        // downloads.json is a file a person can edit.
        let tampered = DownloadItem(
            id: "aaaaaaaaaaa-720", video: VideoSummary(id: "aaaaaaaaaaa", title: "A"), quality: .video(maxHeight: 720),
            state: .completed, progress: 1, bytesDownloaded: 14, bytesTotal: 14, relativeFilePath: "../outside.mp4"
        )
        try JSONEncoder().encode([tampered]).write(to: root.appendingPathComponent("downloads.json"))

        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)
        let item = try #require(manager.items.first)
        #expect(item.state == .failed)
        #expect(manager.fileURL(for: tampered) == nil)
        manager.delete(id: item.id)
        #expect(FileManager.default.fileExists(atPath: outside.path), "delete must never reach outside the downloads folder")
    }

    @Test func thePublicInitializerWorksWithAnEphemeralSession() throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        // As AppEnvironment.preview() builds it.
        let manager = DownloadManager(
            rootDirectory: directory.url.appendingPathComponent("Downloads", isDirectory: true),
            streams: DownloadStubResolver { _, _ in throw NoSlopError.network("x") },
            sessionConfiguration: .ephemeral
        )
        #expect(manager.items.isEmpty && manager.bytesOnDisk == 0)
        #expect(manager.completedItem(videoID: "anything") == nil)
        #expect(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("Downloads").path), "the root is created")
    }

    @Test func aCorruptDownloadsFileIsMovedAsideNotDeleted() throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: root.appendingPathComponent("downloads.json"))
        // An older .corrupt file is replaced.
        try Data("older".utf8).write(to: root.appendingPathComponent("downloads.json.corrupt"))

        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)
        #expect(manager.items.isEmpty)
        let aside = try Data(contentsOf: root.appendingPathComponent("downloads.json.corrupt"))
        #expect(aside == garbage)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("downloads.json").path))
    }

    @Test func missingKeysAndBrokenElementsAreTolerated() throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The first item has only the identity keys; the second is unusable; the third is complete.
        let json = """
        [
          {"id": "aaaaaaaaaaa-720", "video": {"id": "aaaaaaaaaaa"}, "quality": {"video": {"maxHeight": 720}}},
          {"nonsense": true},
          {"id": "bbbbbbbbbbb-audio", "video": {"id": "bbbbbbbbbbb", "title": "B"}, "quality": {"audioOnly": {}}, "state": "failed", "progress": 0.5, "errorMessage": "x"}
        ]
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("downloads.json"))

        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)
        #expect(manager.items.map(\.id) == ["aaaaaaaaaaa-720", "bbbbbbbbbbb-audio"], "readable items are kept")
        #expect(manager.items.first?.state == .failed, "missing state decodes as failed")
        #expect(manager.items.last?.errorMessage == "x")
        // What could not be read is kept for inspection.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("downloads.json.corrupt").path))
    }

    @Test func staleWorkDirectoriesAreCleanedUpAtLaunch() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        let work = root.appendingPathComponent(".work", isDirectory: true)
        let orphan = work.appendingPathComponent("zzzzzzzzzzz-720", isDirectory: true)
        let trash = work.appendingPathComponent(".trash", isDirectory: true).appendingPathComponent("leftover", isDirectory: true)
        for folder in [orphan, trash] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 1_000).write(to: folder.appendingPathComponent("video.0.part"))
        }
        _ = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)
        #expect(await awaitDownloadCondition { !FileManager.default.fileExists(atPath: orphan.path) && !FileManager.default.fileExists(atPath: trash.path) })
    }

    // MARK: Resuming from disk

    @Test func retryAfterAnInterruptionFetchesOnlyWhatIsMissing() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        // 100000-byte chunks: the video has two (0 is on disk), the audio has two (both are on disk).
        try DownloadHarness.leaveInterruptedDownload(in: root, state: .downloading, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1])

        var tuning = DownloadTuning.testing
        tuning.chunkSize = 100_000
        let resolver = DownloadStubResolver { _, _ in ZooFixture.streamInfo(server: server) }
        let manager = DownloadHarness.newManager(root: root, resolver: resolver, tuning: tuning)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        // A paused item shows what is really on disk: 100000 video bytes and all 117495 audio bytes of 312773.
        #expect(await awaitDownloadCondition { manager.items.first?.bytesDownloaded == 217_495 })
        #expect(await manager.diskUsage() >= 217_495, "what a paused download holds is part of the space used")
        #expect(manager.items.first?.bytesTotal == 312_773)
        #expect(abs((manager.items.first?.progress ?? 0) - 217_495.0 / 312_773.0) < 0.0001)

        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        let item = try #require(manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        #expect(resolver.callCount == 1, "retry still asks for fresh URLs")
        #expect(server.requests == [DownloadStubServer.LoggedRequest(path: "/video.mp4", range: 100_000...195_277)], "only the missing chunk is fetched")
        let media = try await mediaDurationAndTracks(of: try #require(manager.fileURL(for: item)))
        #expect(abs(media.seconds - 18.93) < 0.05)
        #expect(media.video == 1 && media.audio == 1)
    }

    @Test func retryAfterAnInterruptionStartsOverWhenTheFormatChanged() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try DownloadHarness.leaveInterruptedDownload(in: root, state: .downloading, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1])

        var tuning = DownloadTuning.testing
        tuning.chunkSize = 100_000
        // YouTube now offers a differently sized encode under the same itag: the old parts are worthless.
        let resolver = DownloadStubResolver { _, _ in
            var video = ZooFixture.video(at: server.url("/video.mp4"))
            video.contentLength = ZooFixture.videoBytes
            video.itag = 133
            return ZooFixture.streamInfo(formats: [video, ZooFixture.audio(at: server.url("/audio.m4a"))])
        }
        let manager = DownloadHarness.newManager(root: root, resolver: resolver, tuning: tuning)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })
        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .completed)
        #expect(server.requests.count == 4, "everything was fetched again: two video chunks and two audio chunks")
    }

    @Test func aFinishedSetOfPartsIsMergedOnLaunchWithoutTheNetwork() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try DownloadHarness.leaveInterruptedDownload(in: root, state: .merging, server: server, chunkSize: 100_000, videoChunks: [0, 1], audioChunks: [0, 1])

        let resolver = DownloadStubResolver { _, _ in throw NoSlopError.network("offline") }
        let manager = DownloadHarness.newManager(root: root, resolver: resolver, tuning: .testing)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .completed })

        let item = try #require(manager.items.first)
        let file = try #require(manager.fileURL(for: item))
        #expect(file.lastPathComponent == "Me at the zoo [jNQXAC9IVRw].mp4")
        let media = try await mediaDurationAndTracks(of: file)
        #expect(abs(media.seconds - 18.93) < 0.05)
        #expect(resolver.callCount == 0 && server.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: DownloadWorkspace(root: root).directory(for: ZooFixture.itemID).path))
    }

    @Test func aPlanWithMissingPartsIsNotMergedOnLaunch() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try DownloadHarness.leaveInterruptedDownload(in: root, state: .merging, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1])

        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.items.first?.state == .paused)
    }

    @Test func aRetryThatCannotReachYouTubeKeepsWhatWasAlreadyFetched() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        try DownloadHarness.leaveInterruptedDownload(in: root, state: .downloading, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1])
        let work = DownloadWorkspace(root: root).directory(for: ZooFixture.itemID)

        var tuning = DownloadTuning.testing
        tuning.chunkSize = 100_000
        let online = DownloadTestGate()
        let resolver = DownloadStubResolver { _, _ in
            guard online.isOpen else { throw NoSlopError.network("offline") }
            return ZooFixture.streamInfo(server: server)
        }
        let manager = DownloadHarness.newManager(root: root, resolver: resolver, tuning: tuning)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        // Retry while offline: it fails, but the three parts on disk are not thrown away.
        manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        #expect(manager.items.first?.state == .failed)
        #expect(manager.items.first?.errorMessage == "Can't reach YouTube. Check your connection.")
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("audio.1.part").path))
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("video.0.part").path))

        // They also survive a relaunch...
        let relaunched = DownloadHarness.newManager(root: root, resolver: resolver, tuning: tuning)
        try await Task.sleep(for: .milliseconds(100))
        #expect(relaunched.items.first?.state == .failed)
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("video.0.part").path))

        // ...and the next retry, back online, fetches only the missing chunk.
        online.release()
        relaunched.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(relaunched, ZooFixture.itemID) })
        #expect(relaunched.items.first?.state == .completed, "\(relaunched.items.first?.errorMessage ?? "")")
        #expect(server.requests == [DownloadStubServer.LoggedRequest(path: "/video.mp4", range: 100_000...195_277)])
    }

    // MARK: Events from a session the app did not start (after a relaunch)

    @Test func aChunkThatFinishesWhileTheAppWasDeadResumesTheItem() async throws {
        let directory = try DownloadTestDirectory.make()
        let server = DownloadStubServer()
        defer { directory.remove() }
        try ZooFixture.serveFixtures(on: server)
        let root = directory.url.appendingPathComponent("Downloads", isDirectory: true)
        // Everything is on disk except the video's second chunk.
        try DownloadHarness.leaveInterruptedDownload(in: root, state: .downloading, server: server, chunkSize: 100_000, videoChunks: [0], audioChunks: [0, 1])
        let manager = DownloadHarness.newManager(root: root, resolver: DownloadStubResolver { _, _ in throw NoSlopError.network("x") }, tuning: .testing)
        #expect(await awaitDownloadCondition { manager.items.first?.state == .paused })

        // The system finishes the last chunk; the delegate moves it into place and reports it.
        let workspace = DownloadWorkspace(root: root)
        let last = DownloadTaskDescriptor(itemID: ZooFixture.itemID, stream: .video, chunkIndex: 1)
        let data = try Fixture.data("zoo_video_144p.mp4")
        try data.subdata(in: 100_000..<data.count).write(to: workspace.partURL(for: last))
        manager.handle(.chunkFinished(last, bytes: Int64(data.count - 100_000), inFlightBytes: 0))

        #expect(manager.items.first?.state == .downloading || manager.items.first?.state == .merging)
        #expect(await awaitDownloadCondition { downloadIsSettled(manager, ZooFixture.itemID) })
        let item = try #require(manager.items.first)
        #expect(item.state == .completed, "\(item.errorMessage ?? "")")
        let media = try await mediaDurationAndTracks(of: try #require(manager.fileURL(for: item)))
        #expect(abs(media.seconds - 18.93) < 0.05)
    }

    @Test func eventsForSomethingNobodyIsWaitingForAreIgnored() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let stranger = DownloadTaskDescriptor(itemID: "zzzzzzzzzzz-720", stream: .video, chunkIndex: 0)
        harness.manager.handle(.progress(itemID: stranger.itemID, inFlightBytes: 5))
        harness.manager.handle(.chunkFinished(stranger, bytes: 5, inFlightBytes: 0))
        harness.manager.handle(.chunkFailed(stranger, .network, inFlightBytes: 0))
        #expect(harness.manager.items.isEmpty)

        // An item that is only queued has no job: its events (stale ones from an earlier attempt) change nothing either.
        harness.server.setDelay(0.2)
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        let own = DownloadTaskDescriptor(itemID: ZooFixture.itemID, stream: .video, chunkIndex: 0)
        harness.manager.handle(.chunkFailed(own, .http(status: 403), inFlightBytes: 0))
        harness.manager.handle(.chunkFinished(own, bytes: 195_278, inFlightBytes: 0))
        #expect(harness.manager.items.first?.state == .queued || harness.manager.items.first?.state == .downloading)
        harness.server.setDelay(0)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .completed)
    }

    @Test func aFailedItemIsNotRevivedByAStrayEvent() async throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        harness.server.fail("/video.mp4", with: .status(403))
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .failed)

        let video = DownloadTaskDescriptor(itemID: ZooFixture.itemID, stream: .video, chunkIndex: 0)
        harness.manager.handle(.chunkFinished(video, bytes: 195_278, inFlightBytes: 0))
        harness.manager.handle(.progress(itemID: ZooFixture.itemID, inFlightBytes: 100))
        #expect(harness.manager.items.first?.state == .failed)
    }

    @Test func aFullDiskStopsAtOnceAndKeepsWhatWasFetched() async throws {
        var tuning = DownloadTuning.testing
        tuning.chunkSize = 100_000
        tuning.retryDelay = .seconds(60)   // a failed video chunk waits for its retry, so the job stays open
        let harness = try DownloadHarness.zoo(tuning: tuning)
        defer { harness.cleanUp() }
        harness.server.fail("/video.mp4", with: .network(.networkConnectionLost))
        harness.manager.enqueue(video: ZooFixture.summary, quality: .video(maxHeight: 144))
        let work = harness.workDirectory(for: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { harness.manager.items.first?.state == .downloading })
        // Both audio chunks must have landed before the failure is injected, or one of them is cancelled with the rest.
        #expect(await awaitDownloadCondition {
            ["audio.0.part", "audio.1.part"].allSatisfy { FileManager.default.fileExists(atPath: work.appendingPathComponent($0).path) }
        })

        let video = DownloadTaskDescriptor(itemID: ZooFixture.itemID, stream: .video, chunkIndex: 0)
        harness.manager.handle(.chunkFailed(video, .outOfSpace, inFlightBytes: 0))

        let item = try #require(harness.manager.items.first)
        #expect(item.state == .failed, "no retries for a full disk")
        #expect(item.errorMessage == "There isn't enough free space on this device.")
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("job.json").path), "the plan stays")
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("audio.1.part").path), "so do the parts")
        // And the space they take is reported: the failed row used to add up to nothing, so nothing said what filled the phone.
        let planSize = Int64(try work.appendingPathComponent("job.json").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        #expect(await harness.manager.diskUsage() == ZooFixture.audioBytes + planSize)
        #expect(harness.manager.bytesOnDisk == 0, "bytesOnDisk is the finished downloads only")

        // Space is back (and the video server too): the retry fetches only what is missing.
        harness.server.clearFaults()
        let before = harness.server.requests.count
        harness.manager.retry(id: ZooFixture.itemID)
        #expect(await awaitDownloadCondition { downloadIsSettled(harness.manager, ZooFixture.itemID) })
        #expect(harness.manager.items.first?.state == .completed, "\(harness.manager.items.first?.errorMessage ?? "")")
        let fetched = harness.server.requests.dropFirst(before).filter { $0.path == "/audio.m4a" }
        #expect(fetched.isEmpty, "the audio was not downloaded again")
    }

    // MARK: Background session plumbing

    @Test func backgroundEventsForAnotherSessionAreAcknowledgedAtOnce() throws {
        let harness = try DownloadHarness.zoo()
        defer { harness.cleanUp() }
        let called = DownloadTestCounter()
        harness.manager.handleEventsForBackgroundURLSession(identifier: "com.robinjungerich.noslopyt.downloads") {
            called.increment()
        }
        // This manager runs on an ephemeral session, so there is nothing to wait for: iOS must not be kept waiting.
        #expect(called.value == 1)
    }
}

// MARK: - File names

@Suite struct DownloadFileNamingTests {
    @Test func sanitizesTheCharactersTheFileSystemDislikes() {
        #expect(DownloadFileNaming.sanitizedTitle("AC/DC: Back In Black?") == "AC-DC- Back In Black-")
        #expect(DownloadFileNaming.sanitizedTitle("a\\b%c*d|e\"f<g>h") == "a-b-c-d-e-f-g-h")
        #expect(DownloadFileNaming.sanitizedTitle("Line\nbreak\tand\u{0}nul") == "Line break and nul")
    }

    @Test func titlesAreTrimmedAndCannotHide() {
        #expect(DownloadFileNaming.sanitizedTitle("  spaced  ") == "spaced")
        #expect(DownloadFileNaming.sanitizedTitle(".hidden") == "-hidden")
        #expect(DownloadFileNaming.sanitizedTitle("...") == "---")
        #expect(DownloadFileNaming.sanitizedTitle("") == "Video")
        #expect(DownloadFileNaming.sanitizedTitle("   ") == "Video")
        #expect(DownloadFileNaming.sanitizedTitle("trailing dot.") == "trailing dot")
    }

    @Test func longTitlesAreCutAtEightyCharacters() {
        let title = String(repeating: "x", count: 200)
        #expect(DownloadFileNaming.sanitizedTitle(title).count == 80)
        let emoji = String(repeating: "🎬", count: 100)
        let cut = DownloadFileNaming.sanitizedTitle(emoji)
        #expect(cut.count <= 80)
        #expect(cut.utf8.count <= 200, "stays well inside the 255-byte file name limit")
        #expect(!cut.isEmpty)
    }

    @Test func baseNameCarriesTheVideoID() {
        #expect(DownloadFileNaming.baseName(title: "Me at the zoo", videoID: "jNQXAC9IVRw") == "Me at the zoo [jNQXAC9IVRw]")
        #expect(DownloadFileNaming.baseName(title: "", videoID: "jNQXAC9IVRw") == "Video [jNQXAC9IVRw]")
        #expect(DownloadFileNaming.baseName(title: "x", videoID: "../../etc") == "x [..-..-etc]")
    }

    @Test func collisionsGetTheQualityAndThenANumber() throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        func destination(taken: Set<String>) -> String {
            DownloadFileNaming.destination(
                in: directory.url, baseName: "Title [abc]", fileExtension: "mp4", qualityLabel: "720p",
                isTaken: { taken.contains($0.lowercased()) }
            ).lastPathComponent
        }
        #expect(destination(taken: []) == "Title [abc].mp4")
        #expect(destination(taken: ["title [abc].mp4"]) == "Title [abc] (720p).mp4", "case-insensitive, like APFS")
        #expect(destination(taken: ["title [abc].mp4", "title [abc] (720p).mp4"]) == "Title [abc] (720p) 2.mp4")
        #expect(destination(taken: ["title [abc].mp4", "title [abc] (720p).mp4", "title [abc] (720p) 2.mp4"]) == "Title [abc] (720p) 3.mp4")
    }
}

// MARK: - Session delegate and workspace

@Suite struct DownloadSessionDelegateTests {
    private func makeDelegate(progressInterval: TimeInterval = 0.25) throws -> (DownloadSessionDelegate, AsyncStream<DownloadEvent>, DownloadTestDirectory) {
        let directory = try DownloadTestDirectory.make()
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadEvent.self)
        let delegate = DownloadSessionDelegate(workspace: DownloadWorkspace(root: directory.url), events: continuation, progressInterval: progressInterval)
        return (delegate, stream, directory)
    }

    @Test func theHandlerWaitsForTheEndOfTheEvents() throws {
        let (delegate, _, directory) = try makeDelegate()
        defer { directory.remove() }
        let called = DownloadTestCounter()
        delegate.registerBackgroundCompletion { called.increment() }
        #expect(called.value == 0, "iOS must be kept waiting until every event has been handled")
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
        #expect(called.value == 1)
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
        #expect(called.value == 1, "once")
    }

    @Test func aHandlerThatArrivesAfterTheEventsWereDeliveredIsCalledAtOnce() throws {
        let (delegate, _, directory) = try makeDelegate()
        defer { directory.remove() }
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
        let called = DownloadTestCounter()
        delegate.registerBackgroundCompletion { called.increment() }
        #expect(called.value == 1, "the session is created before UIKit hands over its handler")
        // The signal is used up.
        let second = DownloadTestCounter()
        delegate.registerBackgroundCompletion { second.increment() }
        #expect(second.value == 0)
    }

    @Test func aNewHandlerReleasesTheOldOne() throws {
        let (delegate, _, directory) = try makeDelegate()
        defer { directory.remove() }
        let first = DownloadTestCounter()
        let second = DownloadTestCounter()
        delegate.registerBackgroundCompletion { first.increment() }
        delegate.registerBackgroundCompletion { second.increment() }
        #expect(first.value == 1 && second.value == 0, "a handler iOS gave us is never dropped")
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
        #expect(second.value == 1)
    }

    @Test func shuttingDownReleasesAWaitingHandlerAndEndsTheEventStream() async throws {
        let (delegate, stream, directory) = try makeDelegate()
        defer { directory.remove() }
        let called = DownloadTestCounter()
        delegate.registerBackgroundCompletion { called.increment() }
        delegate.shutdown()
        #expect(called.value == 1)
        var received = 0
        for await _ in stream { received += 1 }
        #expect(received == 0, "the stream finished")
    }

    @Test func tasksCannotBeTrackedAfterShutdown() async throws {
        let (delegate, _, directory) = try makeDelegate()
        defer { directory.remove() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://stub.test/x")!)
        #expect(delegate.track(task, itemID: "a-720"))
        delegate.shutdown()
        #expect(!delegate.track(task, itemID: "b-720"))
        task.cancel()
    }
}

@Suite struct DownloadWorkspaceTests {
    @Test func itemIDsCanNeverLeaveTheWorkFolder() throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let workspace = DownloadWorkspace(root: directory.url)
        let work = workspace.workRoot.standardizedFileURL.path
        for id in ["../../etc/passwd", "..", ".", "/absolute", "a/b", "a\\b", "", "with space", "ümlaut", "dQw4w9WgXcQ-720"] {
            let url = workspace.directory(for: id).standardizedFileURL
            #expect(url.deletingLastPathComponent().path == work, "\(id) -> \(url.path)")
            #expect(!url.lastPathComponent.isEmpty && url.lastPathComponent != "." && url.lastPathComponent != "..")
        }
        #expect(workspace.directory(for: "dQw4w9WgXcQ-720").lastPathComponent == "dQw4w9WgXcQ-720")
        #expect(workspace.directory(for: "a/b").lastPathComponent != workspace.directory(for: "a-b").lastPathComponent)
    }

    @Test func discardingRemovesTheDirectoryAtOnceAndItsContentsSoon() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let workspace = DownloadWorkspace(root: directory.url)
        let item = workspace.directory(for: "abc-720")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        for index in 0..<20 { try Data(count: 10_000).write(to: item.appendingPathComponent("video.\(index).part")) }

        workspace.discard(itemID: "abc-720")
        #expect(!FileManager.default.fileExists(atPath: item.path), "the id can start over right away")
        try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        try Data(count: 5).write(to: item.appendingPathComponent("job.json"))

        // The background deletion of the old contents must not touch the new directory.
        let trash = workspace.workRoot.appendingPathComponent(".trash")
        for _ in 0..<500 {
            if ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.appendingPathComponent("job.json").path))
    }

    @Test func pruningKeepsOnlyTheNamedItems() async throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let workspace = DownloadWorkspace(root: directory.url)
        for id in ["keep-720", "drop-720", "also drop-audio"] {
            try FileManager.default.createDirectory(at: workspace.directory(for: id), withIntermediateDirectories: true)
        }
        workspace.prune(keeping: ["keep-720"])
        #expect(FileManager.default.fileExists(atPath: workspace.directory(for: "keep-720").path))
        #expect(!FileManager.default.fileExists(atPath: workspace.directory(for: "drop-720").path))
        #expect(!FileManager.default.fileExists(atPath: workspace.directory(for: "also drop-audio").path))
    }

    @Test func aPlanSurvivesTheRoundTripAndFailsGracefully() throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let workspace = DownloadWorkspace(root: directory.url)
        let plan = DownloadJobPlan(
            itemID: "abc-720", videoID: "abc", title: "A title",
            video: ZooFixture.video(at: URL(string: "https://example.invalid/v?x=1&y=2")!), audio: ZooFixture.audio(at: URL(string: "https://example.invalid/a")!),
            durationSeconds: 18.933, chunkSize: 4_096, fileExtension: "mp4"
        )
        try workspace.savePlan(plan)
        #expect(workspace.loadPlan(for: "abc-720") == plan)
        #expect(workspace.loadPlan(for: "other-720") == nil)
        try Data("not json".utf8).write(to: workspace.planURL(for: "abc-720"))
        #expect(workspace.loadPlan(for: "abc-720") == nil, "a damaged plan is no plan")
    }

    @Test func planArithmeticMatchesTheChunkPlanner() {
        let plan = DownloadJobPlan(
            itemID: "abc-720", videoID: "abc", title: "t",
            video: ZooFixture.video(at: URL(string: "https://example.invalid/v")!, contentLength: 26_214_400),
            audio: ZooFixture.audio(at: URL(string: "https://example.invalid/a")!, contentLength: 117_495),
            durationSeconds: 1, chunkSize: 10_485_760, fileExtension: "mp4"
        )
        #expect(plan.chunkCount(of: .video) == 3 && plan.chunkCount(of: .audio) == 1 && plan.chunkCount == 4)
        #expect(plan.totalBytes == 26_214_400 + 117_495)
        let video = ChunkPlanner.ranges(totalBytes: 26_214_400)
        for index in 0..<3 {
            #expect(plan.range(of: DownloadTaskDescriptor(itemID: "abc-720", stream: .video, chunkIndex: index)) == video[index])
        }
        #expect(plan.range(of: DownloadTaskDescriptor(itemID: "abc-720", stream: .video, chunkIndex: 3)) == nil)
        #expect(plan.range(of: DownloadTaskDescriptor(itemID: "abc-720", stream: .video, chunkIndex: -1)) == nil)
        #expect(plan.range(of: DownloadTaskDescriptor(itemID: "other-720", stream: .video, chunkIndex: 0)) == nil)
        #expect(plan.chunks().count == 4)
        #expect(plan.chunks().first?.descriptor.stream == .audio, "audio first")

        var audioOnly = plan
        audioOnly.video = nil
        #expect(audioOnly.streams == [.audio] && audioOnly.chunkCount == 1)
        #expect(audioOnly.range(of: DownloadTaskDescriptor(itemID: "abc-720", stream: .video, chunkIndex: 0)) == nil)
    }
}

// MARK: - Storing a chunk

@Suite struct DownloadChunkStoreTests {
    private struct Fixture {
        let directory: DownloadTestDirectory
        let workspace: DownloadWorkspace
        let descriptor = DownloadTaskDescriptor(itemID: "abc-720", stream: .video, chunkIndex: 1)

        init(createWorkDirectory: Bool = true) throws {
            directory = try DownloadTestDirectory.make()
            workspace = DownloadWorkspace(root: directory.url)
            if createWorkDirectory {
                try FileManager.default.createDirectory(at: workspace.directory(for: "abc-720"), withIntermediateDirectories: true)
            }
        }

        func download(bytes: Int) throws -> URL {
            let url = directory.url.appendingPathComponent("CFNetworkDownload_\(UUID().uuidString).tmp")
            try Data(repeating: 7, count: bytes).write(to: url)
            return url
        }

        func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.invalid/v")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }

        func request(range: String?) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://example.invalid/v")!)
            if let range { request.setValue(range, forHTTPHeaderField: "Range") }
            return request
        }

        func store(
            bytes: Int, status: Int = 206, headers: [String: String] = [:], range: String? = "bytes=1000-1099"
        ) throws -> (outcome: DownloadChunkOutcome, source: URL) {
            let source = try download(bytes: bytes)
            let outcome = DownloadChunkStore.store(
                location: source, response: response(status, headers: headers), request: request(range: range),
                descriptor: descriptor, workspace: workspace
            )
            return (outcome, source)
        }

        var part: URL { workspace.partURL(for: descriptor) }
    }

    @Test func aWholeChunkIsMovedIntoPlace() throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        let (outcome, source) = try fixture.store(bytes: 100, headers: ["Content-Range": "bytes 1000-1099/5000"])
        guard case .stored(let bytes) = outcome else { Issue.record("not stored: \(outcome)"); return }
        #expect(bytes == 100)
        #expect(DownloadAssembler.fileSize(fixture.part) == 100)
        #expect(!FileManager.default.fileExists(atPath: source.path), "moved, not copied")
    }

    @Test func aChunkReplacesAnOlderCopy() throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        try Data(repeating: 1, count: 3).write(to: fixture.part)
        let (outcome, _) = try fixture.store(bytes: 100)
        guard case .stored = outcome else { Issue.record("not stored: \(outcome)"); return }
        #expect(DownloadAssembler.fileSize(fixture.part) == 100)
    }

    @Test func aWrongSizeIsNotStored() throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        let (outcome, _) = try fixture.store(bytes: 99)
        guard case .failed(let failure) = outcome else { Issue.record("expected a failure: \(outcome)"); return }
        #expect(failure == .incompleteChunk(expected: 100, actual: 99))
        #expect(!FileManager.default.fileExists(atPath: fixture.part.path))
    }

    @Test func errorStatusesAreFailuresWhateverTheBody() throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        for status in [403, 404, 410, 416, 429, 500, 503] {
            let (outcome, _) = try fixture.store(bytes: 100, status: status)
            guard case .failed(let failure) = outcome else { Issue.record("expected a failure for \(status)"); continue }
            #expect(failure == .http(status: status))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.part.path))
    }

    @Test func a200IsOnlyRightForARangeThatStartsAtZero() throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        let (later, _) = try fixture.store(bytes: 100, status: 200, range: "bytes=1000-1099")
        guard case .failed(.unexpectedResponse) = later else { Issue.record("expected unexpectedResponse: \(later)"); return }

        let (whole, _) = try fixture.store(bytes: 100, status: 200, range: "bytes=0-99")
        guard case .stored(let bytes) = whole else { Issue.record("expected stored: \(whole)"); return }
        #expect(bytes == 100)
    }

    @Test func aContentRangeForOtherBytesIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        let (outcome, _) = try fixture.store(bytes: 100, headers: ["Content-Range": "bytes 0-99/5000"])
        guard case .failed(.unexpectedResponse) = outcome else { Issue.record("expected unexpectedResponse: \(outcome)"); return }
    }

    @Test func aMissingWorkDirectoryMeansNobodyIsWaiting() throws {
        let fixture = try Fixture(createWorkDirectory: false)
        defer { fixture.directory.remove() }
        let (outcome, source) = try fixture.store(bytes: 100)
        guard case .ignored = outcome else { Issue.record("expected ignored: \(outcome)"); return }
        #expect(FileManager.default.fileExists(atPath: source.path), "left for the system to delete")
        #expect(!FileManager.default.fileExists(atPath: fixture.workspace.directory(for: "abc-720").path), "must not recreate the directory")
    }

    @Test func theRangeComesFromThePlanWhenTheRequestIsGone() throws {
        let fixture = try Fixture()
        defer { fixture.directory.remove() }
        let plan = DownloadJobPlan(
            itemID: "abc-720", videoID: "abc", title: "t",
            video: StreamFormat(itag: 298, url: URL(string: "https://example.invalid/v")!, mimeType: "video/mp4; codecs=\"avc1.4D4020\"", contentLength: 250),
            audio: ZooFixture.audio(at: URL(string: "https://example.invalid/a")!),
            durationSeconds: 10, chunkSize: 100, fileExtension: "mp4"
        )
        try fixture.workspace.savePlan(plan)

        // Chunk 1 of 100-byte chunks is bytes 100-199.
        let source = try fixture.download(bytes: 100)
        let outcome = DownloadChunkStore.store(
            location: source, response: fixture.response(206), request: nil,
            descriptor: fixture.descriptor, workspace: fixture.workspace
        )
        guard case .stored(let bytes) = outcome else { Issue.record("expected stored: \(outcome)"); return }
        #expect(bytes == 100)

        // Without the request and without a plan there is nothing to check the chunk against.
        let other = DownloadTaskDescriptor(itemID: "abc-720", stream: .video, chunkIndex: 9)
        let unknown = DownloadChunkStore.store(
            location: try fixture.download(bytes: 100), response: fixture.response(206), request: nil,
            descriptor: other, workspace: fixture.workspace
        )
        guard case .failed(.unexpectedResponse) = unknown else { Issue.record("expected unexpectedResponse: \(unknown)"); return }
    }

    @Test func rangeHeadersParse() {
        #expect(DownloadChunkStore.parseRange("bytes=0-1023") == 0...1023)
        #expect(DownloadChunkStore.parseRange("bytes=10485760-20971519") == 10_485_760...20_971_519)
        #expect(DownloadChunkStore.parseRange("bytes=5-") == nil)
        #expect(DownloadChunkStore.parseRange("bytes=9-3") == nil)
        #expect(DownloadChunkStore.parseRange("items=0-1") == nil)
        #expect(DownloadChunkStore.parseRange(nil) == nil)
        #expect(DownloadChunkStore.parseContentRange("bytes 0-1023/4096") == 0...1023)
        #expect(DownloadChunkStore.parseContentRange("bytes 0-1023/*") == 0...1023)
        #expect(DownloadChunkStore.parseContentRange("bytes */4096") == nil)
    }
}

// MARK: - Assembly

@Suite struct DownloadAssemblerTests {
    @Test func partsAreConcatenatedInIndexOrder() throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let workspace = DownloadWorkspace(root: directory.url)
        let source = try Fixture.data("zoo_video_144p.mp4")
        let video = ZooFixture.video(at: URL(string: "https://example.invalid/v")!)
        let audio = ZooFixture.audio(at: URL(string: "https://example.invalid/a")!)
        let plan = DownloadJobPlan(
            itemID: ZooFixture.itemID, videoID: ZooFixture.videoID, title: "t", video: video, audio: audio,
            durationSeconds: 18.933, chunkSize: 30_000, fileExtension: "mp4"
        )
        try FileManager.default.createDirectory(at: workspace.directory(for: plan.itemID), withIntermediateDirectories: true)
        let ranges = ChunkPlanner.ranges(totalBytes: ZooFixture.videoBytes, chunkSize: 30_000)
        #expect(ranges.count == 7)
        // Write the parts in a scrambled order: file order, not creation order, decides.
        for index in [4, 0, 6, 2, 1, 5, 3] {
            let range = ranges[index]
            let part = workspace.partURL(for: DownloadTaskDescriptor(itemID: plan.itemID, stream: .video, chunkIndex: index))
            try source.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1)).write(to: part)
        }

        let file = try DownloadAssembler.concatenate(.video, of: plan, in: workspace)
        #expect(try Data(contentsOf: file) == source)
        for index in ranges.indices {
            let part = workspace.partURL(for: DownloadTaskDescriptor(itemID: plan.itemID, stream: .video, chunkIndex: index))
            #expect(!FileManager.default.fileExists(atPath: part.path), "parts are deleted once merged")
        }
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("tmp").path))
    }

    @Test func aMissingOrShortPartFailsTheConcatenation() throws {
        let directory = try DownloadTestDirectory.make()
        defer { directory.remove() }
        let workspace = DownloadWorkspace(root: directory.url)
        let plan = DownloadJobPlan(
            itemID: ZooFixture.itemID, videoID: ZooFixture.videoID, title: "t",
            video: ZooFixture.video(at: URL(string: "https://example.invalid/v")!), audio: ZooFixture.audio(at: URL(string: "https://example.invalid/a")!),
            durationSeconds: 18.933, chunkSize: 100_000, fileExtension: "mp4"
        )
        try FileManager.default.createDirectory(at: workspace.directory(for: plan.itemID), withIntermediateDirectories: true)
        let first = workspace.partURL(for: DownloadTaskDescriptor(itemID: plan.itemID, stream: .video, chunkIndex: 0))
        try Data(count: 100_000).write(to: first)
        #expect(throws: DownloadFailure.missingParts) {
            try DownloadAssembler.concatenate(.video, of: plan, in: workspace)
        }
        // A part with the wrong size is just as bad.
        let second = workspace.partURL(for: DownloadTaskDescriptor(itemID: plan.itemID, stream: .video, chunkIndex: 1))
        try Data(count: 5).write(to: second)
        #expect(throws: DownloadFailure.missingParts) {
            try DownloadAssembler.concatenate(.video, of: plan, in: workspace)
        }
        let target = workspace.directory(for: plan.itemID).appendingPathComponent("video.mp4")
        #expect(!FileManager.default.fileExists(atPath: target.path), "no half-built stream file is left to be mistaken for a complete one")
    }
}

// MARK: - Failure classification

@Suite struct DownloadFailureTests {
    private let noSpace = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [NSLocalizedDescriptionKey: "No space left on device"])

    @Test func aFullDiskIsRecognisedInEveryShapeItArrivesIn() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        #expect(DownloadFailure.from(cocoa) == .outOfSpace)
        #expect(DownloadFailure.from(noSpace) == .outOfSpace)
        #expect(DownloadFailure.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))

        // URLSession reports a file it cannot write as its own error, with the real cause underneath.
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotWriteToFile, userInfo: [NSUnderlyingErrorKey: noSpace])
        #expect(DownloadFailure.from(wrapped) == .outOfSpace)
        let twice = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotCreateFile, userInfo: [NSUnderlyingErrorKey: wrapped])
        #expect(DownloadFailure.from(twice) == .outOfSpace)

        // AVFoundation's "Disk Full" (-11807) is one even if the underlying error went missing.
        let avFoundation = NSError(domain: "AVFoundationErrorDomain", code: -11807)
        #expect(DownloadFailure.from(avFoundation) == .outOfSpace)
    }

    @Test func otherFileErrorsFromURLSessionAreNotNetworkErrors() {
        // "Can't reach YouTube" would be a lie about a disk that cannot be written.
        for code in [NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile, NSURLErrorCannotCloseFile, NSURLErrorCannotWriteToFile, NSURLErrorCannotRemoveFile, NSURLErrorCannotMoveFile] {
            let failure = DownloadFailure.from(NSError(domain: NSURLErrorDomain, code: code))
            guard case .fileSystem = failure else { Issue.record("code \(code) became \(failure)"); continue }
            #expect(failure.errorDescription == "Couldn't save the download to disk.")
        }
    }

    @Test func connectionProblemsStayNetworkErrors() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCancelled] {
            #expect(DownloadFailure.from(NSError(domain: NSURLErrorDomain, code: code)) == .network)
        }
        #expect(DownloadFailure.from(URLError(.timedOut)) == .network)
        #expect(!DownloadFailure.isOutOfSpace(URLError(.networkConnectionLost)))
        #expect(!DownloadFailure.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    }

    @Test func aVeryLongChainOfUnderlyingErrorsEndsTheWalk() {
        // Not something the system does, but the walk is bounded: a full-disk error buried deeper than the limit is
        // not found, and nothing hangs or recurses without end.
        var error = noSpace
        for _ in 0..<50 { error = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: error]) }
        #expect(!DownloadFailure.isOutOfSpace(error))
        #expect(DownloadFailure.from(error) == .network)

        // Within the limit it is found.
        var shallow = noSpace
        for _ in 0..<3 { shallow = NSError(domain: "wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: shallow]) }
        #expect(DownloadFailure.isOutOfSpace(shallow))
    }
}
