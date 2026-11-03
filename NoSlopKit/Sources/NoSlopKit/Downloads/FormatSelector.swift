import Foundation

/// The video and audio formats chosen for one download. `video` is nil for audio-only downloads.
public struct SelectedFormats: Sendable, Hashable {
    public var video: StreamFormat?
    public var audio: StreamFormat

    public init(video: StreamFormat? = nil, audio: StreamFormat) {
        self.video = video
        self.audio = audio
    }
}

/// Picks the AVFoundation-compatible formats (H.264 + AAC in MP4) for a download quality.
///
/// STUB (Task 1A). Task 7 owns this file: returns nil until it is filled in.
public enum FormatSelector {
    public static func select(from formats: [StreamFormat], quality: DownloadQuality) -> SelectedFormats? {
        nil
    }
}
