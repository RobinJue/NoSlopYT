import Foundation

/// Decides which SponsorBlock segment (if any) the player should skip now, and which ones to draw in the seek bar.
///
/// What happens to a segment is chosen per category (`SegmentBehavior`); a category without a configured behaviour
/// follows the defaults (`AppSettings.defaultSegmentBehaviors`).
///
/// - `autoSkip`: drawn in the bar and skipped.
/// - `showInBar`: drawn, never skipped.
/// - `ignore`: neither.
///
/// Whatever the setting, a segment is never skipped when it is a highlight (`poi_highlight` category or `poi`
/// action: it marks a moment, not a range), when it is shorter than a second, or when it is malformed. Whole-video
/// labels and chapters are not time ranges and are not drawn either. A `mute` segment is skipped like a `skip` one,
/// because the player cannot mute.
public struct SegmentSkipPlanner: Sendable {
    /// Segments are skipped from their start until this long before their end: skipping the last moments would only
    /// seek to a position playback reaches by itself, and a seek that lands on the end could trigger it again.
    private static let endMargin = 0.5
    /// Segments shorter than this are not worth a jump.
    private static let minimumSkippableLength = 1.0

    /// Auto-skip candidates, by start time.
    private let skippable: [SponsorSegment]
    /// Everything that is drawn, by start time.
    private let visible: [SponsorSegment]

    public init(segments: [SponsorSegment], behaviors: [SponsorCategory: SegmentBehavior]) {
        var skippable: [SponsorSegment] = []
        var visible: [SponsorSegment] = []
        for segment in segments where Self.isWellFormed(segment) {
            let behavior = behaviors[segment.category]
                ?? AppSettings.defaultSegmentBehaviors[segment.category]
                ?? .showInBar
            guard behavior != .ignore else { continue }
            visible.append(segment)
            if behavior == .autoSkip, Self.canBeSkipped(segment) {
                skippable.append(segment)
            }
        }
        self.skippable = skippable.sorted(by: Self.playbackOrder)
        self.visible = visible.sorted(by: Self.playbackOrder)
    }

    /// The auto-skip segment that contains `time`, unless its id is in `alreadySkipped`. When several overlap, the one
    /// that ends last, so a single seek clears them all.
    public func segmentToSkip(at time: Double, alreadySkipped: Set<String>) -> SponsorSegment? {
        guard time.isFinite else { return nil }
        var best: SponsorSegment?
        for segment in skippable {
            if segment.start > time { break }
            guard time < segment.end - Self.endMargin, !alreadySkipped.contains(segment.id) else { continue }
            if segment.end > (best?.end ?? -.infinity) {
                best = segment
            }
        }
        return best
    }

    /// Segments to draw in the seek bar (everything not ignored), in playback order.
    public var visibleSegments: [SponsorSegment] {
        visible
    }

    // MARK: Rules

    private static func isWellFormed(_ segment: SponsorSegment) -> Bool {
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start else { return false }
        // Not time ranges.
        return segment.actionType != .full && segment.actionType != .chapter
    }

    private static func canBeSkipped(_ segment: SponsorSegment) -> Bool {
        segment.category != .poiHighlight
            && segment.actionType != .poi
            && segment.end - segment.start >= minimumSkippableLength
    }

    private static func playbackOrder(_ lhs: SponsorSegment, _ rhs: SponsorSegment) -> Bool {
        (lhs.start, lhs.end, lhs.id) < (rhs.start, rhs.end, rhs.id)
    }
}
