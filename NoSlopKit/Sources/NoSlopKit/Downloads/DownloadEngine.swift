import Foundation
import Synchronization

// The URLSession side of downloads: the background session, one download task per Range chunk, the delegate that
// moves each finished chunk into the work directory, and the file work around it (plan, parts, merging).
// `DownloadManager` drives it; nothing outside `Downloads/` refers to anything in this file.
//
// Layout under the downloads root:
//
//   downloads.json                      the items (DownloadManager)
//   Title [videoID].mp4                 finished downloads (.m4a for audio only)
//   .work/<item id>/job.json            what to fetch and how to merge it (DownloadJobPlan)
//   .work/<item id>/video.3.part        chunk 3 of the video stream, moved here by the session delegate
//   .work/<item id>/video.mp4           the concatenated stream, present only when complete
//   .work/.trash/<uuid>                 directories being deleted in the background
//   .extras/<video id>.json             what a video's downloads keep for offline playback (DownloadExtras)

// MARK: - Failure

/// Why a chunk or a whole download failed. `errorDescription` is a short, plain sentence that goes straight into
/// `DownloadItem.errorMessage`.
enum DownloadFailure: Error, Equatable, Sendable, LocalizedError {
    /// A chunk request was answered with this HTTP status (403 is what an expired or refused link looks like).
    case http(status: Int)
    case network
    case incompleteChunk(expected: Int64, actual: Int64)
    case unexpectedResponse
    case noDownloadableFormat
    case unknownSize
    case tooLarge
    case liveStream
    case outOfSpace
    /// The device cannot hold this download: checked before anything is fetched. `needed` counts what is still to be
    /// fetched and the room the merge takes at the end; both are bytes.
    case notEnoughSpace(needed: Int64, free: Int64)
    case fileSystem(String)
    case mergeFailed(String)
    /// The system cut the merge short (the app was suspended in the middle of it, media services were reset). Nothing
    /// is wrong with the downloaded files, so they are kept for the retry.
    case mergeInterrupted
    case missingParts

    var errorDescription: String? {
        switch self {
        case .http(let status) where status == 403 || status == 404 || status == 410:
            return "YouTube refused the download (HTTP \(status)). Retry to get a fresh link."
        case .http(let status):
            return "YouTube returned an error (HTTP \(status))."
        case .network:
            return "Can't reach YouTube. Check your connection."
        case .incompleteChunk:
            return "A piece of the download arrived incomplete."
        case .unexpectedResponse:
            return "YouTube sent an unexpected response."
        case .noDownloadableFormat:
            return "This video has no format that can be downloaded."
        case .unknownSize:
            return "Couldn't work out how big the download is."
        case .tooLarge:
            return "This download is too large."
        case .liveStream:
            return "Live streams can't be downloaded."
        case .outOfSpace:
            return "There isn't enough free space on this device."
        case .notEnoughSpace(let needed, let free):
            // Short, with both figures near the front: the failed row shows this in a narrow column beside the thumbnail
            // and the Retry button, where it wraps to four or five lines. "To finish" hints at why the figure is about
            // twice the size the download is offered at: the merge writes a second copy before the streams are removed.
            let formatter: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "There isn't enough free space: this needs about \(formatter(needed)) to finish, \(formatter(free)) is free."
        case .fileSystem:
            return "Couldn't save the download to disk."
        case .mergeFailed:
            return "Couldn't combine the video and audio."
        case .mergeInterrupted:
            return "Interrupted while combining the video and audio. Retry to finish."
        case .missingParts:
            return "Some downloaded pieces are missing."
        }
    }

    /// True when the stream address itself has stopped working, as opposed to the server being busy: 403 is what an
    /// expired link, or one made for an IP address the phone has since left, is answered with, and 410 says it is gone.
    /// Asking YouTube for a new address can help; asking the same address again cannot.
    var isDeadLink: Bool {
        if case .http(let status) = self { return status == 403 || status == 410 }
        return false
    }

    /// Whether what is already on disk is still worth keeping after the download failed like this: a full disk (or a
    /// download that would not fit), a merge that was interrupted, a disk that could not be written, parts that went
    /// missing. None of these says anything
    /// against the downloaded data, and a retry carries on from it.
    var keepsDownloadedData: Bool {
        switch self {
        case .outOfSpace, .notEnoughSpace, .mergeInterrupted, .fileSystem, .missingParts: return true
        default: return false
        }
    }

    /// Maps what URLSession or the file system reported for a chunk.
    static func from(_ error: any Error) -> DownloadFailure {
        if let failure = error as? DownloadFailure { return failure }
        if isOutOfSpace(error) { return .outOfSpace }
        if isInterrupted(error) { return .mergeInterrupted }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            // URLSession reports a file it cannot write in its own domain; that is the disk's problem, not the network's.
            switch ns.code {
            case NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile, NSURLErrorCannotCloseFile,
                 NSURLErrorCannotWriteToFile, NSURLErrorCannotRemoveFile, NSURLErrorCannotMoveFile:
                return .fileSystem(ns.localizedDescription)
            default:
                return .network
            }
        }
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain { return .fileSystem(ns.localizedDescription) }
        return .network
    }

    /// True when `error`, or an error it wraps, says the volume is full. A full disk arrives in several shapes: a Cocoa
    /// write error, POSIX ENOSPC, URLSession's "cannot write to file" around one of those, and AVFoundation's
    /// "Disk Full" (-11807, which wraps ENOSPC) when the export runs out of room. The walk is bounded.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 8 {
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
            if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
            if ns.domain == "AVFoundationErrorDomain" && ns.code == -11807 { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// AVFoundation's codes for "the system cut this short": operation interrupted (-11847), session was interrupted
    /// (-11818), media services were reset (-11819), and decoder / encoder temporarily unavailable (-11839, -11840).
    /// They are compared as numbers because the first three exist on iOS only: the macOS build the tests run on has no
    /// names for them.
    private static let interruptionCodes: Set<Int> = [-11847, -11818, -11819, -11839, -11840]

    /// True when `error`, or an error it wraps, is one of `interruptionCodes`: the system stopped the merge (an app that
    /// is suspended in the middle of an export is the usual cause), the files are not at fault. The walk is bounded.
    static func isInterrupted(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 8 {
            if ns.domain == "AVFoundationErrorDomain" && interruptionCodes.contains(ns.code) { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}

// MARK: - Tuning

/// The numbers the downloader runs with. Production uses `standard`; tests shrink the chunks and skip the waiting.
struct DownloadTuning: Sendable {
    /// Bytes per Range request (10 MiB: googlevideo serves requests of this size at full speed).
    var chunkSize: Int64 = ChunkPlanner.defaultChunkSize
    /// How often one chunk is requested again after it failed.
    var maxChunkRetries = 2
    /// Wait before retry number n is n times this.
    var retryDelay: Duration = .milliseconds(400)
    /// At most one progress update per item per this many seconds.
    var progressInterval: TimeInterval = 0.25
    /// Combines the downloaded streams into one file. Tests replace it to make merges fail (or wait) the way they can on
    /// a device.
    var mux: DownloadMuxer = { videoFile, audioFile, durationSeconds, output in
        try await MediaMuxer.mux(videoFile: videoFile, audioFile: audioFile, durationSeconds: durationSeconds, output: output)
    }
    /// How many bytes are free on the volume of the given folder; nil when that cannot be told, and the download then
    /// goes ahead. Tests replace it to run out of room without filling a disk.
    var availableCapacity: @Sendable (URL) -> Int64? = { DownloadAssembler.availableCapacity(at: $0) }
    /// How long a download that starts waits for the extras of its video (SponsorBlock segments, chapters, captions).
    /// After that it starts without them.
    var extrasTimeout: Duration = .seconds(8)
    /// Borrows running time from the system for work that must not be cut short by the app being suspended (the start of
    /// a download, a merge): `BackgroundTime`. Tests replace it to see when time is held and given back.
    var backgroundTime: BackgroundTimeSource = { BackgroundTime(name: $0) }

    static let standard = DownloadTuning()
}

/// What combines a video file and an audio file into the finished file: `MediaMuxer.mux`, unless a test says otherwise.
typealias DownloadMuxer = @Sendable (_ videoFile: URL?, _ audioFile: URL, _ durationSeconds: Double, _ output: URL) async throws -> Void

// MARK: - Events

/// What the session delegate tells the manager, in the order it happened. `inFlightBytes` is what the item's other
/// running chunks have written so far.
enum DownloadEvent: Sendable {
    case progress(itemID: String, inFlightBytes: Int64)
    case chunkFinished(DownloadTaskDescriptor, bytes: Int64, inFlightBytes: Int64)
    case chunkFailed(DownloadTaskDescriptor, DownloadFailure, inFlightBytes: Int64)
}

// MARK: - Plan

/// One Range request.
struct DownloadChunk: Sendable, Hashable {
    var descriptor: DownloadTaskDescriptor
    var url: URL
    var range: ClosedRange<Int64>
}

/// Everything needed to fetch, resume and merge one item. It is written to the work directory before the first task
/// starts, so after the app was killed the chunks that finished meanwhile still know where they belong.
struct DownloadJobPlan: Codable, Hashable, Sendable {
    var itemID: String
    var videoID: String
    /// Names the final file.
    var title: String
    /// nil for audio-only. Content lengths must be known (the manager fills them in before planning).
    var video: StreamFormat?
    var audio: StreamFormat
    /// The true duration the merged tracks are cut to; zero when unknown.
    var durationSeconds: Double
    var chunkSize: Int64
    /// "mp4", or "m4a" for audio only.
    var fileExtension: String

    /// Audio first: it is small, so an unusable audio link shows up before gigabytes of video are fetched.
    var streams: [DownloadTaskDescriptor.Stream] {
        video == nil ? [.audio] : [.audio, .video]
    }

    func format(for stream: DownloadTaskDescriptor.Stream) -> StreamFormat? {
        stream == .video ? video : audio
    }

    func length(of stream: DownloadTaskDescriptor.Stream) -> Int64 {
        max(0, format(for: stream)?.contentLength ?? 0)
    }

    var totalBytes: Int64 {
        streams.reduce(0) { $0 + length(of: $1) }
    }

    func chunkCount(of stream: DownloadTaskDescriptor.Stream) -> Int {
        let length = length(of: stream)
        guard length > 0, chunkSize > 0 else { return 0 }
        return Int(length / chunkSize) + (length % chunkSize == 0 ? 0 : 1)
    }

    var chunkCount: Int {
        streams.reduce(0) { $0 + chunkCount(of: $1) }
    }

    /// The bytes this chunk covers, nil when it does not belong to the plan.
    func range(of descriptor: DownloadTaskDescriptor) -> ClosedRange<Int64>? {
        guard descriptor.itemID == itemID, streams.contains(descriptor.stream),
              descriptor.chunkIndex >= 0, descriptor.chunkIndex < chunkCount(of: descriptor.stream)
        else { return nil }
        let length = length(of: descriptor.stream)
        let start = Int64(descriptor.chunkIndex) * chunkSize
        let end = length - start > chunkSize ? start + chunkSize - 1 : length - 1
        return start...end
    }

    func contains(_ descriptor: DownloadTaskDescriptor) -> Bool {
        range(of: descriptor) != nil
    }

    /// Every request of the plan, in the order they are started.
    func chunks() -> [DownloadChunk] {
        var result: [DownloadChunk] = []
        for stream in streams {
            guard let format = format(for: stream) else { continue }
            for (index, range) in ChunkPlanner.ranges(totalBytes: length(of: stream), chunkSize: chunkSize).enumerated() {
                result.append(DownloadChunk(
                    descriptor: DownloadTaskDescriptor(itemID: itemID, stream: stream, chunkIndex: index),
                    url: format.url,
                    range: range
                ))
            }
        }
        return result
    }

    func chunk(for descriptor: DownloadTaskDescriptor) -> DownloadChunk? {
        guard let range = range(of: descriptor), let format = format(for: descriptor.stream) else { return nil }
        return DownloadChunk(descriptor: descriptor, url: format.url, range: range)
    }

    /// True when parts fetched for `other` are still good for this plan: same streams, sizes and chunking.
    /// The URLs may differ (they are re-resolved on retry).
    func isCompatible(with other: DownloadJobPlan) -> Bool {
        itemID == other.itemID
            && chunkSize == other.chunkSize
            && fileExtension == other.fileExtension
            && video?.itag == other.video?.itag
            && video?.contentLength == other.video?.contentLength
            && audio.itag == other.audio.itag
            && audio.contentLength == other.audio.contentLength
    }
}

// MARK: - Workspace

/// Paths and housekeeping of the downloads root. A value type, so the session delegate (which runs on its own
/// queue) and the manager share it freely.
struct DownloadWorkspace: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    var workRoot: URL { root.appendingPathComponent(".work", isDirectory: true) }
    private var trashRoot: URL { workRoot.appendingPathComponent(".trash", isDirectory: true) }

    /// Item ids come from video ids, which are safe, but they also arrive through links and a JSON file: anything
    /// outside letters, digits, "-" and "_" is percent-encoded so an id can never leave `.work`.
    func directory(for itemID: String) -> URL {
        workRoot.appendingPathComponent(Self.directoryName(for: itemID), isDirectory: true)
    }

    static func directoryName(for itemID: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let encoded = itemID.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return encoded.isEmpty ? "item" : encoded
    }

    func partURL(for descriptor: DownloadTaskDescriptor) -> URL {
        directory(for: descriptor.itemID)
            .appendingPathComponent("\(descriptor.stream.rawValue).\(descriptor.chunkIndex).part")
    }

    /// The concatenated stream; it only exists once it is complete.
    func streamFileURL(_ stream: DownloadTaskDescriptor.Stream, itemID: String) -> URL {
        directory(for: itemID).appendingPathComponent(stream == .video ? "video.mp4" : "audio.m4a")
    }

    func planURL(for itemID: String) -> URL {
        directory(for: itemID).appendingPathComponent("job.json")
    }

    func loadPlan(for itemID: String) -> DownloadJobPlan? {
        guard let data = try? Data(contentsOf: planURL(for: itemID)) else { return nil }
        return try? JSONDecoder().decode(DownloadJobPlan.self, from: data)
    }

    func savePlan(_ plan: DownloadJobPlan) throws {
        let directory = directory(for: plan.itemID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: planURL(for: plan.itemID), options: .atomic)
    }

    /// Removes the item's directory. The directory is renamed out of the way first (instant), then deleted in the
    /// background: a download can have thousands of parts, and the same id may start over right away.
    func discard(itemID: String) {
        let directory = directory(for: itemID)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return }
        discardInBackground(directory)
    }

    /// Deletes everything in `.work` that does not belong to one of `keeping`, and empties the trash.
    func prune(keeping itemIDs: Set<String>) {
        let fileManager = FileManager.default
        let keep = Set(itemIDs.map(Self.directoryName(for:)))
        if let entries = try? fileManager.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil) {
            for entry in entries where entry.lastPathComponent != ".trash" && !keep.contains(entry.lastPathComponent) {
                discardInBackground(entry)
            }
        }
        if let leftovers = try? fileManager.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil) {
            for entry in leftovers { Self.removeInBackground(entry) }
        }
    }

    private func discardInBackground(_ directory: URL) {
        let fileManager = FileManager.default
        let trash = trashRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: trashRoot, withIntermediateDirectories: true)
            try fileManager.moveItem(at: directory, to: trash)
            Self.removeInBackground(trash)
        } catch {
            // Could not move it aside: delete it in place, in the background.
            Self.removeInBackground(directory)
        }
    }

    private static func removeInBackground(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Room on the device

/// How much free space a download needs.
enum DownloadSpace {
    /// Kept free on top of what the download itself takes, so that it never fills the device to the last byte.
    static let margin: Int64 = 64 * 1_048_576

    /// What must be free before `totalBytes` of streams are fetched when `presentBytes` of them are on disk already.
    ///
    /// The streams are fetched in full (`totalBytes`), and then the merge writes the combined file next to them before
    /// they are removed: at its peak the download holds twice its size. Whatever is on disk already has been paid for.
    /// A merge-only retry (everything is on disk) needs about one more copy.
    static func needed(totalBytes: Int64, presentBytes: Int64) -> Int64 {
        max(0, 2 * totalBytes - presentBytes) + margin
    }
}

// MARK: - Assembly

/// Turns the fetched parts into the final file. Every step is restartable from what is on disk: a stream file exists
/// only when complete (it is written under a `.tmp` name and renamed), so a killed merge simply resumes.
enum DownloadAssembler {
    struct Present {
        var chunks: Set<DownloadTaskDescriptor> = []
        var bytes: Int64 = 0
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    /// The bytes available for the volume `url` is on, counting what the system would free up if it had to (cached
    /// files, say): the number the system itself shows as available for something the person asked for. nil when the
    /// volume does not say.
    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// `provider`'s answer for `url`, asked off the main actor: the system can take a moment to work out what it could
    /// free up.
    @concurrent
    static func freeSpace(at url: URL, using provider: @Sendable (URL) -> Int64?) async -> Int64? {
        provider(url)
    }

    /// The bytes of every file under the downloads folder, measured on disk off the main actor: the finished downloads
    /// and the work directories of the ones that are not finished (parts, concatenated streams, plans). Not counted are
    /// the trash (directories that are being deleted) and the list of downloads with its saved copy of a damaged one,
    /// which are not downloads. A file that is deleted while the walk is on it is simply not counted.
    @concurrent
    static func diskUsage(under root: URL) async -> Int64 {
        sizeOfFiles(under: root)
    }

    static func sizeOfFiles(under root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var total: Int64 = 0
        while let url = walker.nextObject() as? URL {
            let name = url.lastPathComponent
            if walker.level == 2, name == ".trash", url.deletingLastPathComponent().lastPathComponent == ".work" {
                walker.skipDescendants()
                continue
            }
            if walker.level == 1, name.hasPrefix("downloads.json") { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, let size = values.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// The chunks that need no download: parts of exactly the right size, and every chunk of a stream whose
    /// concatenated file is complete. With `cleanUp`, everything else in the directory (short parts, temp files,
    /// an unfinished merge) is deleted.
    static func present(in plan: DownloadJobPlan, workspace: DownloadWorkspace, cleanUp: Bool = false) -> Present {
        let fileManager = FileManager.default
        var result = Present()
        var keep: Set<String> = ["job.json"]

        for stream in plan.streams {
            let streamFile = workspace.streamFileURL(stream, itemID: plan.itemID)
            let length = plan.length(of: stream)
            if fileSize(streamFile) == length {
                keep.insert(streamFile.lastPathComponent)
                for index in 0..<plan.chunkCount(of: stream) {
                    result.chunks.insert(DownloadTaskDescriptor(itemID: plan.itemID, stream: stream, chunkIndex: index))
                }
                result.bytes += length
                continue
            }
            for index in 0..<plan.chunkCount(of: stream) {
                let descriptor = DownloadTaskDescriptor(itemID: plan.itemID, stream: stream, chunkIndex: index)
                guard let range = plan.range(of: descriptor) else { continue }
                let part = workspace.partURL(for: descriptor)
                if fileSize(part) == range.upperBound - range.lowerBound + 1 {
                    keep.insert(part.lastPathComponent)
                    result.chunks.insert(descriptor)
                    result.bytes += range.upperBound - range.lowerBound + 1
                }
            }
        }

        if cleanUp,
           let entries = try? fileManager.contentsOfDirectory(at: workspace.directory(for: plan.itemID), includingPropertiesForKeys: nil) {
            for entry in entries where !keep.contains(entry.lastPathComponent) {
                try? fileManager.removeItem(at: entry)
            }
        }
        return result
    }

    /// Gets the item's directory ready for `plan`. Parts of an earlier attempt are kept when that attempt had the
    /// same streams and sizes (the app was killed mid-download, the formats did not change): a retry then fetches
    /// only what is missing. Anything else is thrown away. The plan on disk is replaced by this one.
    @concurrent
    static func prepare(plan: DownloadJobPlan, workspace: DownloadWorkspace) async throws -> Present {
        let fileManager = FileManager.default
        let directory = workspace.directory(for: plan.itemID)
        var reusable = false
        if let earlier = workspace.loadPlan(for: plan.itemID), earlier.isCompatible(with: plan),
           fileManager.fileExists(atPath: directory.path) {
            reusable = true
        }
        if !reusable {
            workspace.discard(itemID: plan.itemID)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try workspace.savePlan(plan)
        return present(in: plan, workspace: workspace, cleanUp: true)
    }

    /// Concatenates the parts into the stream file (`video.mp4` / `audio.m4a`), checks the size, and deletes the
    /// parts. Does nothing when the stream file already exists.
    @discardableResult
    static func concatenate(
        _ stream: DownloadTaskDescriptor.Stream,
        of plan: DownloadJobPlan,
        in workspace: DownloadWorkspace
    ) throws -> URL {
        let fileManager = FileManager.default
        let target = workspace.streamFileURL(stream, itemID: plan.itemID)
        if fileSize(target) == plan.length(of: stream) { return target }

        let partial = target.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: partial)
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw DownloadFailure.fileSystem("Couldn't create \(partial.lastPathComponent).")
        }
        var finished = false
        defer { if !finished { try? fileManager.removeItem(at: partial) } }

        let output = try FileHandle(forWritingTo: partial)
        var written: Int64 = 0
        do {
            for index in 0..<plan.chunkCount(of: stream) {
                try Task.checkCancellation()
                let descriptor = DownloadTaskDescriptor(itemID: plan.itemID, stream: stream, chunkIndex: index)
                guard let range = plan.range(of: descriptor) else { throw DownloadFailure.missingParts }
                let expected = range.upperBound - range.lowerBound + 1
                let part = workspace.partURL(for: descriptor)
                guard fileSize(part) == expected else { throw DownloadFailure.missingParts }
                try append(part, to: output)
                written += expected
            }
            guard written == plan.length(of: stream) else { throw DownloadFailure.missingParts }
            try output.synchronize()
            try output.close()
        } catch is CancellationError {
            try? output.close()
            throw CancellationError()
        } catch {
            try? output.close()
            throw DownloadFailure.from(error)
        }

        try? fileManager.removeItem(at: target)
        do {
            try fileManager.moveItem(at: partial, to: target)
        } catch {
            throw DownloadFailure.from(error)
        }
        finished = true

        for index in 0..<plan.chunkCount(of: stream) {
            try? fileManager.removeItem(at: workspace.partURL(for: DownloadTaskDescriptor(itemID: plan.itemID, stream: stream, chunkIndex: index)))
        }
        return target
    }

    private static func append(_ part: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: part)
        defer { try? input.close() }
        while true {
            let block: Data? = try autoreleasepool { try input.read(upToCount: 1 << 20) }
            guard let block, !block.isEmpty else { return }
            try output.write(contentsOf: block)
        }
    }

    /// Concatenates, muxes with the true duration and moves the result to `destination`. Returns its size.
    /// Cancellable; leaves the work directory for the caller to remove.
    @concurrent
    static func assemble(
        plan: DownloadJobPlan,
        workspace: DownloadWorkspace,
        destination: URL,
        mux: DownloadMuxer = DownloadTuning.standard.mux
    ) async throws -> Int64 {
        let fileManager = FileManager.default
        var videoFile: URL?
        var audioFile: URL?
        for stream in plan.streams {
            let file = try concatenate(stream, of: plan, in: workspace)
            if stream == .video { videoFile = file } else { audioFile = file }
        }
        guard let audioFile else { throw DownloadFailure.missingParts }
        try Task.checkCancellation()

        let merged = workspace.directory(for: plan.itemID).appendingPathComponent("merged.\(plan.fileExtension)")
        try await mux(videoFile, audioFile, plan.durationSeconds, merged)
        try Task.checkCancellation()

        guard let size = fileSize(merged), size > 0 else { throw DownloadFailure.mergeFailed("The merged file is empty.") }
        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: merged, to: destination)
        } catch {
            throw DownloadFailure.from(error)
        }
        excludeFromBackup(destination)
        return size
    }

    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - Storing a finished chunk

/// What happened to a chunk the session finished downloading.
enum DownloadChunkOutcome: Sendable {
    case stored(bytes: Int64)
    case failed(DownloadFailure)
    /// Nobody is waiting for this chunk any more (the item was cancelled and its directory removed).
    case ignored
}

enum DownloadChunkStore {
    /// Checks the response and moves the downloaded file to `.work/<item>/<stream>.<index>.part`. The caller is the
    /// session delegate, and the temporary file is deleted as soon as it returns, so the move happens here.
    static func store(
        location: URL,
        response: URLResponse?,
        request: URLRequest?,
        descriptor: DownloadTaskDescriptor,
        workspace: DownloadWorkspace
    ) -> DownloadChunkOutcome {
        // What was asked for is in the request's Range header; if the system did not keep the request across a
        // relaunch, the plan on disk knows it just as well.
        guard let http = response as? HTTPURLResponse,
              let requested = parseRange(request?.value(forHTTPHeaderField: "Range"))
                ?? workspace.loadPlan(for: descriptor.itemID)?.range(of: descriptor)
        else { return .failed(.unexpectedResponse) }

        // 206 is the answer to a Range request. A 200 is only right when the range is the whole file.
        switch http.statusCode {
        case 206: break
        case 200 where requested.lowerBound == 0: break
        case 200..<300: return .failed(.unexpectedResponse)
        default: return .failed(.http(status: http.statusCode))
        }

        if let header = http.value(forHTTPHeaderField: "Content-Range"), let served = parseContentRange(header),
           served.lowerBound != requested.lowerBound || served.upperBound < requested.upperBound {
            return .failed(.unexpectedResponse)
        }

        let expected = requested.upperBound - requested.lowerBound + 1
        let actual = DownloadAssembler.fileSize(location) ?? -1
        guard actual == expected else { return .failed(.incompleteChunk(expected: expected, actual: actual)) }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: workspace.directory(for: descriptor.itemID).path) else { return .ignored }
        let destination = workspace.partURL(for: descriptor)
        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
        } catch {
            return .failed(DownloadFailure.from(error))
        }
        return .stored(bytes: actual)
    }

    /// "bytes=0-1023"
    static func parseRange(_ header: String?) -> ClosedRange<Int64>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let lower = Int64(parts[0]), let upper = Int64(parts[1]), lower >= 0, lower <= upper else { return nil }
        return lower...upper
    }

    /// "bytes 0-1023/4096" (the total may be "*")
    static func parseContentRange(_ header: String) -> ClosedRange<Int64>? {
        guard header.hasPrefix("bytes ") else { return nil }
        let span = header.dropFirst("bytes ".count).split(separator: "/", maxSplits: 1).first ?? ""
        let parts = span.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let lower = Int64(parts[0]), let upper = Int64(parts[1]), lower <= upper else { return nil }
        return lower...upper
    }
}

// MARK: - Session delegate

/// Receives the URLSession callbacks on the session's own serial queue. It moves finished chunks into place right
/// there (the system deletes the download when the callback returns) and reports everything else to the manager as
/// events. It keeps no job state: the manager owns that.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        /// Tasks this engine started, by item, so they can be cancelled without asking the session.
        var tracked: [String: [Int: URLSessionTask]] = [:]
        /// Bytes written so far by each running chunk, by item.
        var written: [String: [DownloadTaskDescriptor: Int64]] = [:]
        var lastProgress: [String: TimeInterval] = [:]
        /// Tasks whose outcome `didFinishDownloadingTo` already reported.
        var reported: Set<Int> = []
        var cancelledByUs: Set<Int> = []
        var backgroundCompletion: (@Sendable () -> Void)?
        var finishedEventsAt: TimeInterval?
        var isShutdown = false
    }

    private let state = Mutex(State())
    private let workspace: DownloadWorkspace
    private let events: AsyncStream<DownloadEvent>.Continuation
    private let progressInterval: TimeInterval

    init(workspace: DownloadWorkspace, events: AsyncStream<DownloadEvent>.Continuation, progressInterval: TimeInterval) {
        self.workspace = workspace
        self.events = events
        self.progressInterval = progressInterval
    }

    static func descriptor(of task: URLSessionTask) -> DownloadTaskDescriptor? {
        task.taskDescription.flatMap { DownloadTaskDescriptor(encoded: $0) }
    }

    // MARK: Called by the engine

    /// Remembers `task` so it can be cancelled later. False once the engine is shut down.
    func track(_ task: URLSessionTask, itemID: String) -> Bool {
        state.withLock { state in
            guard !state.isShutdown else { return false }
            state.tracked[itemID, default: [:]][task.taskIdentifier] = task
            return true
        }
    }

    func isTracked(_ task: URLSessionTask, itemID: String) -> Bool {
        state.withLock { $0.tracked[itemID]?[task.taskIdentifier] != nil }
    }

    func cancelTracked(itemID: String) {
        let tasks = state.withLock { state -> [URLSessionTask] in
            let removed = state.tracked.removeValue(forKey: itemID) ?? [:]
            for identifier in removed.keys { state.cancelledByUs.insert(identifier) }
            return Array(removed.values)
        }
        for task in tasks { task.cancel() }
    }

    /// Cancels a task found through the session (one a previous launch started).
    func cancel(_ task: URLSessionTask) {
        state.withLock { _ = $0.cancelledByUs.insert(task.taskIdentifier) }
        task.cancel()
    }

    func shutdown() {
        let completion = state.withLock { state -> (@Sendable () -> Void)? in
            state.isShutdown = true
            let completion = state.backgroundCompletion
            state.backgroundCompletion = nil
            return completion
        }
        events.finish()
        completion?()
    }

    /// iOS relaunched the app for background events and wants to know when they have all been handled.
    func registerBackgroundCompletion(_ handler: @escaping @Sendable () -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        let (callNow, replaced) = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
            // The delegate may already have seen the end of the events (the session is created before UIKit calls us).
            if let finished = state.finishedEventsAt, now - finished < 15 {
                state.finishedEventsAt = nil
                return (true, nil)
            }
            let replaced = state.backgroundCompletion
            state.backgroundCompletion = handler
            return (false, replaced)
        }
        replaced?()
        if callNow { handler() }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let descriptor = Self.descriptor(of: downloadTask) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let inFlight: Int64? = state.withLock { state in
            state.written[descriptor.itemID, default: [:]][descriptor] = totalBytesWritten
            if let last = state.lastProgress[descriptor.itemID], now - last < progressInterval { return nil }
            state.lastProgress[descriptor.itemID] = now
            return state.written[descriptor.itemID]?.values.reduce(0, +)
        }
        if let inFlight { events.yield(.progress(itemID: descriptor.itemID, inFlightBytes: inFlight)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let descriptor = Self.descriptor(of: downloadTask) else { return }
        let identifier = downloadTask.taskIdentifier
        let cancelled = state.withLock { $0.cancelledByUs.contains(identifier) }

        // The file must be moved before this method returns, whatever the manager is doing.
        let outcome: DownloadChunkOutcome = cancelled
            ? .ignored
            : DownloadChunkStore.store(
                location: location,
                response: downloadTask.response,
                request: downloadTask.originalRequest ?? downloadTask.currentRequest,
                descriptor: descriptor,
                workspace: workspace
            )

        let inFlight = state.withLock { state -> Int64 in
            state.reported.insert(identifier)
            state.written[descriptor.itemID]?[descriptor] = nil
            return state.written[descriptor.itemID]?.values.reduce(0, +) ?? 0
        }
        switch outcome {
        case .stored(let bytes):
            events.yield(.chunkFinished(descriptor, bytes: bytes, inFlightBytes: inFlight))
        case .failed(let failure):
            events.yield(.chunkFailed(descriptor, failure, inFlightBytes: inFlight))
        case .ignored:
            break
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let identifier = task.taskIdentifier
        let descriptor = Self.descriptor(of: task)
        let (alreadyReported, cancelledByUs, inFlight) = state.withLock { state -> (Bool, Bool, Int64) in
            let reported = state.reported.remove(identifier) != nil
            let cancelled = state.cancelledByUs.remove(identifier) != nil
            var inFlight: Int64 = 0
            if let descriptor {
                state.written[descriptor.itemID]?[descriptor] = nil
                inFlight = state.written[descriptor.itemID]?.values.reduce(0, +) ?? 0
                state.tracked[descriptor.itemID]?[identifier] = nil
                if state.tracked[descriptor.itemID]?.isEmpty == true { state.tracked[descriptor.itemID] = nil }
                if state.written[descriptor.itemID]?.isEmpty == true { state.written[descriptor.itemID] = nil }
            }
            return (reported, cancelled, inFlight)
        }
        // A successful chunk (or a bad status) was reported from didFinishDownloadingTo; a cancel was our own doing.
        guard let descriptor, !alreadyReported, !cancelledByUs else { return }
        let failure = error.map(DownloadFailure.from) ?? .unexpectedResponse
        events.yield(.chunkFailed(descriptor, failure, inFlightBytes: inFlight))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let now = ProcessInfo.processInfo.systemUptime
        let handler = state.withLock { state -> (@Sendable () -> Void)? in
            guard let handler = state.backgroundCompletion else {
                state.finishedEventsAt = now
                return nil
            }
            state.backgroundCompletion = nil
            return handler
        }
        handler?()
    }
}

// MARK: - Engine

/// The URLSession: one download task per chunk, a delegate that stores finished chunks, and cancellation. Safe to
/// use from any thread.
final class DownloadEngine: Sendable {
    /// The identifier of the app's background session.
    static let backgroundSessionIdentifier = "com.robinjungerich.noslopyt.downloads"

    /// nil for a non-background configuration.
    let sessionIdentifier: String?
    private let session: URLSession
    private let delegate: DownloadSessionDelegate

    /// - Parameter configuration: nil means the background configuration with the global session id.
    init(
        configuration: URLSessionConfiguration?,
        workspace: DownloadWorkspace,
        events: AsyncStream<DownloadEvent>.Continuation,
        progressInterval: TimeInterval
    ) {
        let configuration = configuration.map { ($0.copy() as? URLSessionConfiguration) ?? $0 }
            ?? URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil

        let delegate = DownloadSessionDelegate(workspace: workspace, events: events, progressInterval: progressInterval)
        let queue = OperationQueue()
        queue.name = "\(Self.backgroundSessionIdentifier).delegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility

        self.delegate = delegate
        self.sessionIdentifier = configuration.identifier
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    /// Starts one download task per chunk. Each asks for its byte range only; the task description says which chunk
    /// it is, which is all a relaunched app has to go on.
    func start(_ chunks: [DownloadChunk]) {
        for chunk in chunks {
            var request = URLRequest(url: chunk.url)
            request.setValue("bytes=\(chunk.range.lowerBound)-\(chunk.range.upperBound)", forHTTPHeaderField: "Range")
            // Byte ranges are of the stored file, never of a compressed copy.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue(ClientProfile.visionOS.userAgent, forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            task.taskDescription = chunk.descriptor.encoded
            guard delegate.track(task, itemID: chunk.descriptor.itemID) else {
                task.cancel()
                return
            }
            task.resume()
        }
    }

    /// Cancels the tasks this engine started for the item.
    func cancelTasks(itemID: String) {
        delegate.cancelTracked(itemID: itemID)
    }

    /// Cancels the item's tasks that an earlier launch of the app started (a background session keeps its tasks across
    /// launches). The ones this engine started are `cancelTasks`' business; leaving them alone here means a sweep that
    /// runs late can never cancel the tasks of a newer attempt at the same item.
    func cancelInheritedTasks(itemID: String) async {
        for task in await session.allTasks {
            guard Self.isActive(task), DownloadSessionDelegate.descriptor(of: task)?.itemID == itemID,
                  !delegate.isTracked(task, itemID: itemID)
            else { continue }
            delegate.cancel(task)
        }
    }

    /// The chunks that still have a running (or waiting) task, from the session itself: after a relaunch this is how
    /// the manager learns what the system kept downloading.
    func liveChunks() async -> Set<DownloadTaskDescriptor> {
        Set(await session.allTasks.compactMap { Self.isActive($0) ? DownloadSessionDelegate.descriptor(of: $0) : nil })
    }

    /// Keeps iOS's completion handler until the delegate has seen all events. A handler for another session is
    /// called right away.
    func registerBackgroundCompletion(identifier: String, handler: @escaping @Sendable () -> Void) {
        guard identifier == sessionIdentifier else {
            handler()
            return
        }
        delegate.registerBackgroundCompletion(handler)
    }

    /// Ends the event stream and releases the session. A background session keeps its tasks.
    func shutdown() {
        delegate.shutdown()
        if sessionIdentifier == nil {
            session.invalidateAndCancel()
        } else {
            session.finishTasksAndInvalidate()
        }
    }

    private static func isActive(_ task: URLSessionTask) -> Bool {
        task.state == .running || task.state == .suspended
    }
}
