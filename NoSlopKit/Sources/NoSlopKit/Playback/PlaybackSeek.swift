import Foundation

/// Where the player seeks to: the limits every seek obeys, and where skipping a SponsorBlock segment lands.
public enum PlaybackSeek {
    /// How far before the end a seek to (or past) the end lands.
    ///
    /// AVPlayer parked exactly at the end of an item waits there for media that never comes
    /// (`waitingToMinimizeStalls`, with no end to the wait). A moment earlier it plays out and reaches the end the usual
    /// way, which is what ends the video, starts the queue and records the progress.
    public static let endMargin = 0.25

    /// A skip that moves the playhead by less than this is not a skip.
    public static let minimumSkip = 0.05

    /// `seconds` limited to what can be played: not before the start and, once the duration is known, not later than
    /// `endMargin` before the end. A live stream has no end to keep away from, an unknown duration (zero) no limit; a
    /// time that is not a number goes to the start.
    public static func clamped(_ seconds: Double, duration: Double, isLive: Bool) -> Double {
        guard seconds.isFinite else { return 0 }
        var value = max(0, seconds)
        if duration.isFinite, duration > 0, !isLive {
            value = min(value, max(0, duration - endMargin))
        }
        return value
    }

    /// Where skipping `segment` from `time` lands: its end, limited like every seek. Nil when that would not move the
    /// playhead forward, which is the case once playback is already within `endMargin` of the end of a segment that
    /// runs to (or past) the end of the video; skipping again would only repeat the notice.
    public static func skipDestination(
        of segment: SponsorSegment,
        from time: Double,
        duration: Double,
        isLive: Bool
    ) -> Double? {
        guard time.isFinite else { return nil }
        let destination = clamped(segment.end, duration: duration, isLive: isLive)
        return destination - time >= minimumSkip ? destination : nil
    }
}
