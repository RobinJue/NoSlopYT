import Foundation

/// When the player saves the watch position to the library while a video plays.
///
/// `LibraryStore` rewrites `history.json` (up to about 4 MB) for every batch of changes, and every change redraws the
/// screens that show progress. So a playing video saves once every `interval` seconds, not on every tick of the
/// player's clock. The moments that must not lose the position (pause, close, background, the end of the video and a
/// switch to another one) save at once: they pass `force: true`.
public struct ProgressSaveThrottle: Equatable, Sendable {
    /// Seconds between two saves while a video plays.
    public static let interval: TimeInterval = 10

    private var lastSave: Date?

    public init() {}

    /// Whether the position is to be saved at `now`. Saying yes starts the next interval at `now`; saying no leaves
    /// the interval running.
    public mutating func shouldSave(now: Date, force: Bool = false) -> Bool {
        if !force, let lastSave {
            let elapsed = now.timeIntervalSince(lastSave)
            // A clock that was set back counts as time that has passed.
            if elapsed >= 0, elapsed < Self.interval {
                return false
            }
        }
        lastSave = now
        return true
    }
}
