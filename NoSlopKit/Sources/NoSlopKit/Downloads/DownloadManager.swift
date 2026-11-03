import Foundation
import Observation

/// Chunked background downloads with duration-clamped muxing, and the list of downloaded videos.
///
/// STUB (Task 1A). Task 7 owns this file and adds the real URLSession engine. Until then this is a simple, fully
/// working in-memory list so UI tasks can use it: `enqueue` adds a `.queued` item at the front (newest first) and
/// nothing is ever downloaded, so items never progress. `rootDirectory` and the session configuration are not used
/// for network or disk work.
@MainActor
@Observable
public final class DownloadManager {
    /// Newest first.
    public private(set) var items: [DownloadItem] = []

    @ObservationIgnored private let rootDirectory: URL
    @ObservationIgnored private let streams: any StreamResolving

    /// - Parameter sessionConfiguration: nil means the background configuration with the global session id.
    public init(rootDirectory: URL, streams: any StreamResolving, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.rootDirectory = rootDirectory
        self.streams = streams
    }

    /// The qualities the sheet offers for this video. The stub offers the standard ladder without size estimates.
    public func availableOptions(for info: StreamInfo) -> [DownloadOption] {
        let video = [1080, 720, 480, 360].map { height in
            DownloadOption(quality: .video(maxHeight: height), label: "\(height)p")
        }
        return video + [DownloadOption(quality: .audioOnly, label: DownloadQuality.audioOnly.label)]
    }

    /// Adds a `.queued` item at the front. A failed or paused item for the same video and quality is re-queued;
    /// anything else already in the list is left alone.
    public func enqueue(video: VideoSummary, quality: DownloadQuality) {
        let id = "\(video.id)-\(quality.key)"
        if let index = items.firstIndex(where: { $0.id == id }) {
            guard items[index].state == .failed || items[index].state == .paused else { return }
            items[index].state = .queued
            items[index].progress = 0
            items[index].bytesDownloaded = 0
            items[index].errorMessage = nil
            return
        }
        items.insert(DownloadItem(id: id, video: video, quality: quality, state: .queued), at: 0)
    }

    /// Stops a download that has not finished and removes it from the list.
    public func cancel(id: String) {
        items.removeAll { $0.id == id && $0.state != .completed }
    }

    /// Removes the item (and, in the real implementation, its file).
    public func delete(id: String) {
        items.removeAll { $0.id == id }
    }

    /// Puts a failed or paused item back in the queue.
    public func retry(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .queued
        items[index].progress = 0
        items[index].bytesDownloaded = 0
        items[index].errorMessage = nil
    }

    public func completedItem(videoID: String) -> DownloadItem? {
        items.first { $0.video.id == videoID && $0.state == .completed }
    }

    /// The file of a finished item, resolved against the downloads root; nil while it has no file.
    public func fileURL(for item: DownloadItem) -> URL? {
        guard let relativeFilePath = item.relativeFilePath else { return nil }
        return rootDirectory.appendingPathComponent(relativeFilePath)
    }

    /// Total size of the finished downloads.
    public var bytesOnDisk: Int64 {
        items.filter { $0.state == .completed }.reduce(0) { $0 + ($1.bytesTotal ?? $1.bytesDownloaded) }
    }

    /// Called from the app delegate when iOS relaunches the app for finished background transfers.
    /// The stub has no session, so it reports completion right away.
    public func handleEventsForBackgroundURLSession(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
        completionHandler()
    }
}
