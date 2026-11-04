import AVFoundation
import Foundation

/// Combines a downloaded video file and audio file into one playable file, clamping both tracks to the true
/// duration (AVFoundation reports twice the real length for YouTube's fragmented MP4 streams).
///
/// Nothing is re-encoded: both tracks go into an `AVMutableComposition` and out through the passthrough export
/// preset, so muxing a long video costs one sequential write of the file. Only a couple of exports run at once in the
/// whole process, however many merges are asked for: the rest wait their turn (`ExportGate`).
public enum MediaMuxer {
    /// - Parameters:
    ///   - videoFile: nil for audio-only downloads, which are written as `.m4a`.
    ///   - durationSeconds: the true duration (the format's `approxDurationMs`, or the video's `lengthSeconds`).
    ///     Each track is cut to at most this long; zero or less means "unknown" and leaves the tracks unclamped.
    ///   - output: replaced when it already exists, and not left behind when the export fails.
    public static func mux(videoFile: URL?, audioFile: URL, durationSeconds: Double, output: URL) async throws {
        try await mux(videoFile: videoFile, audioFile: audioFile, durationSeconds: durationSeconds, output: output, gate: .shared)
    }

    /// `gate` decides how many exports run at once. Production code always uses `ExportGate.shared`; tests hand in a
    /// gate of their own.
    static func mux(videoFile: URL?, audioFile: URL, durationSeconds: Double, output: URL, gate: ExportGate) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: output)

        let limit: CMTime? = durationSeconds.isFinite && durationSeconds > 0
            ? CMTime(seconds: durationSeconds, preferredTimescale: 600)
            : nil

        let composition = AVMutableComposition()
        if let videoFile {
            try await insertFirstTrack(of: .video, from: videoFile, into: composition, limit: limit)
        }
        try await insertFirstTrack(of: .audio, from: audioFile, into: composition, limit: limit)

        // The export blocks a thread of the cooperative pool for as long as it waits for CoreMedia, so only a few run at a
        // time (see `ExportGate`). The permit is taken before the session exists and given back however the export ends;
        // a merge that is cancelled while it waits for its turn leaves the line without exporting anything.
        try await gate.withPermit {
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw DownloadFailure.mergeFailed("The export preset isn't available.")
            }
            do {
                try await session.export(to: output, as: videoFile == nil ? .m4a : .mp4)
            } catch {
                try? fileManager.removeItem(at: output)
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw failure(forExportError: error)
            }
        }
    }

    /// What a failed export means for the download. Two things that are not the files' fault are told apart from a
    /// merge that really failed, so that the downloaded streams are kept and a retry only has to merge again:
    ///
    /// - The export needs room for a second copy of the video, so a nearly full device fails right here. That is a full
    ///   disk (`.outOfSpace`), not a failed merge.
    /// - The system can stop an export that is in progress, most of all by suspending the app when its background time
    ///   runs out. AVFoundation then reports an interruption (`.mergeInterrupted`).
    static func failure(forExportError error: any Error) -> DownloadFailure {
        if DownloadFailure.isOutOfSpace(error) { return .outOfSpace }
        if DownloadFailure.isInterrupted(error) { return .mergeInterrupted }
        return .mergeFailed(error.localizedDescription)
    }

    /// Adds the first track of `mediaType` in `file` to `composition`, at most `limit` long.
    private static func insertFirstTrack(
        of mediaType: AVMediaType,
        from file: URL,
        into composition: AVMutableComposition,
        limit: CMTime?
    ) async throws {
        let kind = mediaType == .video ? "video" : "audio"
        let asset = AVURLAsset(url: file)

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: mediaType)
        } catch {
            // Cut short by the system while the file was being read: the file may be perfectly good.
            if DownloadFailure.isInterrupted(error) { throw DownloadFailure.mergeInterrupted }
            throw DownloadFailure.mergeFailed("The downloaded \(kind) can't be read (\(error.localizedDescription)).")
        }
        guard let source = tracks.first else {
            throw DownloadFailure.mergeFailed("The downloaded \(kind) file has no \(kind) track.")
        }

        let sourceRange = try await source.load(.timeRange)
        let length = limit.map { CMTimeMinimum($0, sourceRange.duration) } ?? sourceRange.duration
        guard length.isValid, length > .zero else {
            throw DownloadFailure.mergeFailed("The downloaded \(kind) is empty.")
        }
        guard let destination = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw DownloadFailure.mergeFailed("Couldn't add a \(kind) track.")
        }
        do {
            try destination.insertTimeRange(CMTimeRange(start: sourceRange.start, duration: length), of: source, at: .zero)
        } catch {
            throw DownloadFailure.mergeFailed("Couldn't use the downloaded \(kind) (\(error.localizedDescription)).")
        }
    }
}
