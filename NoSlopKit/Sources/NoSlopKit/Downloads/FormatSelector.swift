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
/// Only `video/mp4` `avc1` video-only streams and `audio/mp4` `mp4a` streams qualify: they are what
/// `AVMutableComposition` can combine without re-encoding. VP9, AV1 and Opus are skipped even when they are the
/// only choice, and so are progressive formats (their audio would be a second copy).
public enum FormatSelector {
    /// The heights the quality sheet offers, highest first.
    static let ladder = [1080, 720, 480, 360]

    /// - Returns: nil when no compatible audio exists, or (for a video quality) no compatible video.
    public static func select(from formats: [StreamFormat], quality: DownloadQuality) -> SelectedFormats? {
        guard let audio = bestAudio(in: formats) else { return nil }
        switch quality {
        case .audioOnly:
            return SelectedFormats(video: nil, audio: audio)
        case .video(let maxHeight):
            guard let video = bestVideo(in: formats, maxHeight: maxHeight) else { return nil }
            return SelectedFormats(video: video, audio: audio)
        }
    }

    // MARK: Quality sheet

    /// What the quality sheet offers for these formats: the rungs of `ladder` that give a distinct video, highest
    /// first, then audio only. A rung nothing exists for is left out, and so is one that would repeat a higher or lower
    /// rung (a video that stops at 720p has no 1080p entry), so a label always names what is really downloaded.
    static func options(from formats: [StreamFormat]) -> [DownloadOption] {
        var video: [(height: Int, option: DownloadOption)] = []
        var seen: Set<Int> = []
        for rung in ladder {
            guard let selected = select(from: formats, quality: .video(maxHeight: rung)),
                  let chosen = selected.video,
                  let height = resolution(of: chosen),
                  seen.insert(height).inserted
            else { continue }
            let quality = DownloadQuality.video(maxHeight: height)
            video.append((height, DownloadOption(
                quality: quality,
                label: quality.label,
                estimatedBytes: estimatedBytes(chosen, selected.audio)
            )))
        }

        var options = video.sorted { $0.height > $1.height }.map(\.option)
        if let audio = select(from: formats, quality: .audioOnly)?.audio {
            options.append(DownloadOption(
                quality: .audioOnly,
                label: DownloadQuality.audioOnly.label,
                estimatedBytes: knownSize(audio)
            ))
        }
        return options
    }

    /// The size YouTube states for a format. Zero or less means "not stated" (the download itself treats it that way
    /// and falls back to the URL's `clen`).
    private static func knownSize(_ format: StreamFormat) -> Int64? {
        guard let length = format.contentLength, length > 0 else { return nil }
        return length
    }

    /// Video plus audio, or nil when either is unknown or the sum does not fit (the sizes come from the network, and
    /// a plain `+` would trap on absurd ones).
    private static func estimatedBytes(_ video: StreamFormat, _ audio: StreamFormat) -> Int64? {
        guard let videoBytes = knownSize(video), let audioBytes = knownSize(audio) else { return nil }
        let (sum, overflow) = videoBytes.addingReportingOverflow(audioBytes)
        return overflow ? nil : sum
    }

    // MARK: Ranking

    /// The resolution class of a video format: the number in its quality label ("1080p60" is 1080), otherwise the
    /// shorter side. YouTube names renditions by the short side, so a 1080x1920 portrait video is still "1080p";
    /// comparing `height` alone would class it as 1920p.
    static func resolution(of format: StreamFormat) -> Int? {
        if let label = format.qualityLabel, let fromLabel = leadingNumber(of: label) {
            return fromLabel
        }
        switch (format.width, format.height) {
        case (let width?, let height?): return height > 0 && width > 0 ? min(width, height) : nil
        case (nil, let height?): return height > 0 ? height : nil
        default: return nil
        }
    }

    /// 1080 for "1080p60", 720 for "720p"; nil unless the digits are followed by "p".
    private static func leadingNumber(of label: String) -> Int? {
        let digits = label.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits), value > 0 else { return nil }
        let next = label.dropFirst(digits.count).first
        guard next == "p" || next == "P" else { return nil }
        return value
    }

    /// Plain audio beats the dynamic-range-compressed copy; then the higher bitrate (itag 140 over 139), sample rate
    /// and size; the itag only makes the choice independent of the order the formats came in.
    private static func bestAudio(in formats: [StreamFormat]) -> StreamFormat? {
        func rank(_ format: StreamFormat) -> (Int, Int, Int, Int64, Int) {
            (format.isDRC ? 0 : 1, format.bitrate ?? 0, format.audioSampleRate ?? 0, format.contentLength ?? 0, format.itag)
        }
        return formats
            .filter { $0.isAudioOnly && $0.isAVFoundationCompatible }
            .max { rank($0) < rank($1) }
    }

    /// The tallest rendition not above `maxHeight` (more frames per second, then more bitrate, on a tie); when every
    /// rendition is taller than the cap, the smallest one there is. A rendition that does not say how tall it is
    /// counts as 0: always allowed, chosen only when nothing better is there.
    private static func bestVideo(in formats: [StreamFormat], maxHeight: Int) -> StreamFormat? {
        let candidates: [(format: StreamFormat, height: Int)] = formats.compactMap { format in
            guard format.isVideoOnly, format.isAVFoundationCompatible else { return nil }
            return (format, resolution(of: format) ?? 0)
        }

        func rank(_ candidate: (format: StreamFormat, height: Int)) -> (Int, Int, Int, Int) {
            (candidate.height, candidate.format.fps ?? 0, candidate.format.bitrate ?? 0, candidate.format.itag)
        }

        if let best = candidates.filter({ $0.height <= maxHeight }).max(by: { rank($0) < rank($1) }) {
            return best.format
        }
        return candidates.min { rank($0) < rank($1) }?.format
    }
}
