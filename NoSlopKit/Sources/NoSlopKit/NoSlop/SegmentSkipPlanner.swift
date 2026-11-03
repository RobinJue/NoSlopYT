import Foundation

/// Decides which SponsorBlock segment (if any) the player should skip now, and which ones to draw in the seek bar.
///
/// STUB (Task 1A). Task 6 owns this file: nothing is ever skipped or shown until it is filled in.
public struct SegmentSkipPlanner: Sendable {
    public init(segments: [SponsorSegment], behaviors: [SponsorCategory: SegmentBehavior]) {}

    /// The auto-skip segment that contains `time`, unless its id is in `alreadySkipped`.
    public func segmentToSkip(at time: Double, alreadySkipped: Set<String>) -> SponsorSegment? {
        nil
    }

    /// Segments to draw in the seek bar (everything not ignored).
    public var visibleSegments: [SponsorSegment] {
        []
    }
}
