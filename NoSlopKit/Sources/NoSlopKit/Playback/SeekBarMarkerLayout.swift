import Foundation

/// Where the seek bar draws a SponsorBlock segment, in points from the left edge of the bar.
///
/// A segment with a length (a sponsor read, an intro) is a stretch of the bar: it starts where the segment starts and
/// is as wide as the segment is long, but never narrower than `minimumStretchWidth`, so that a few seconds of a long
/// video can still be seen. A segment that marks a moment (a highlight: `poi_highlight` category, `poi` action, start
/// and end are the same second) has no width on the bar at all, so it is drawn as a tick of `momentWidth` centred on
/// that second, moved inwards where it would stick out of the bar.
///
/// Nothing is drawn while the length of the video is unknown (a link or a pasted URL opens the player with none until
/// the stream is resolved): every time maps to the left edge then, and every segment would pile up there.
public enum SeekBarMarkerLayout {
    /// The width of the tick that marks a moment.
    public static let momentWidth = 4.0
    /// The narrowest a stretch is drawn.
    public static let minimumStretchWidth = 2.0

    public struct Frame: Equatable, Sendable {
        /// From the left edge of the bar to the left edge of the marker.
        public var x: Double
        public var width: Double

        public init(x: Double, width: Double) {
            self.x = x
            self.width = width
        }
    }

    /// The frame of `segment` in a bar `width` points wide that stands for `duration` seconds; nil when the segment has
    /// no place on the bar: the length is unknown, the bar has no width, the segment lies beyond the end of the video
    /// (or before its start), or it ends before it starts.
    ///
    /// A stretch is judged by its position on the bar (one that lies completely beyond the end covers nothing); a
    /// moment by its time in seconds.
    public static func frame(for segment: SponsorSegment, duration: Double, width: Double) -> Frame? {
        guard duration.isFinite, duration > 0, width.isFinite, width > 0,
              segment.start.isFinite, segment.end.isFinite else { return nil }

        if segment.end > segment.start {
            let start = fraction(segment.start, of: duration)
            let end = fraction(segment.end, of: duration)
            guard end > start else { return nil }
            return Frame(x: width * start, width: max(minimumStretchWidth, width * (end - start)))
        }

        guard segment.end == segment.start, segment.start >= 0, segment.start <= duration else { return nil }
        let tick = min(momentWidth, width)
        let centre = width * fraction(segment.start, of: duration)
        return Frame(x: min(max(centre - tick / 2, 0), width - tick), width: tick)
    }

    private static func fraction(_ time: Double, of duration: Double) -> Double {
        min(max(time / duration, 0), 1)
    }
}
