import Foundation

/// Hold to scan: holding the left half of the video goes backwards at twice the speed, holding the right half forwards
/// at twice the speed, for as long as the finger stays down.
public enum PlaybackScan {
    public enum Direction: Sendable, Equatable {
        case backward
        case forward
    }

    /// How fast a scan goes, in seconds of video per second.
    public static let speed = 2.0

    /// How long the video has to be held (without the finger moving) before the scan starts. A tap, a double tap and the
    /// drag that minimizes the player all end sooner.
    public static let holdDelay = 0.35

    /// A finger that moves further than this (in points) before the hold counts has not held still: it is a drag.
    public static let holdSlop = 12.0

    /// How far from the asked time a backward scan may land. A little slack lets the player show a frame it has nearly at
    /// hand instead of decoding from the keyframe before it for every step.
    public static let seekTolerance = 0.25

    /// The side a press at `x` in a view `width` wide scans toward: the left half back, the right half forward (the
    /// halves a double tap uses).
    public static func direction(forTouchAt x: Double, width: Double) -> Direction {
        x < width / 2 ? .backward : .forward
    }

    /// Where a backward scan that began at `start` is after `elapsed` seconds. Never before the start of the video; a time
    /// or an elapsed time that is not a number stays where the scan began.
    public static func reverseTarget(from start: Double, elapsed: Double) -> Double {
        guard start.isFinite else { return 0 }
        guard elapsed.isFinite, elapsed > 0 else { return max(0, start) }
        return max(0, start - speed * elapsed)
    }
}
