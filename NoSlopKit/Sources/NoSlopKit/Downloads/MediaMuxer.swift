import Foundation

/// Combines a downloaded video file and audio file into one playable file, clamping both tracks to the true
/// duration (AVFoundation reports twice the real length for YouTube's fragmented MP4 streams).
///
/// STUB (Task 1A). Task 7 owns this file: `mux` throws `NoSlopError.notImplemented`.
public enum MediaMuxer {
    /// - Parameter videoFile: nil for audio-only downloads, which are written as `.m4a`.
    public static func mux(videoFile: URL?, audioFile: URL, durationSeconds: Double, output: URL) async throws {
        throw NoSlopError.notImplemented("MediaMuxer.mux")
    }
}
