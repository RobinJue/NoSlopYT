import Foundation

/// Counts played media time for one viewing and says when to report it.
/// Only small forward steps while playing count: seeks, skips, pauses and stalls add nothing.
public struct WatchReportTracker: Sendable, Equatable {
    static let qualifyingSeconds = 30.0
    static let progressSeconds = 240.0
    static let maxStep = 2.0
    static let finishedFraction = 0.95

    private var lengthSeconds: Double
    private let disabled: Bool
    private var lastPosition: Double?
    private var played = 0.0
    private var qualified = false
    private var playedAtLastReport = 0.0

    public init(lengthSeconds: Double, isLive: Bool, isShort: Bool) {
        self.lengthSeconds = lengthSeconds
        self.disabled = isLive || isShort
    }

    /// Tells the tracker the length once the player knows it; the time already counted is kept.
    public mutating func setLength(_ seconds: Double) {
        if seconds.isFinite, seconds > 0 { lengthSeconds = seconds }
    }

    public mutating func tick(position: Double, isPlaying: Bool) -> WatchEvent? {
        guard !disabled else { return nil }
        defer { lastPosition = position }
        if isPlaying, let last = lastPosition {
            let step = position - last
            if step > 0, step <= Self.maxStep { played += step }
        }
        if !qualified {
            let shortVideo = lengthSeconds > 0 && lengthSeconds < Self.qualifyingSeconds
            let reachedEnd = shortVideo && isPlaying && played > 0 && position >= lengthSeconds - 0.5
            if played >= Self.qualifyingSeconds - 1e-6 || reachedEnd {
                qualified = true
                playedAtLastReport = played
                return .qualified(position: position)
            }
            return nil
        }
        if played - playedAtLastReport >= Self.progressSeconds - 1e-6 {
            playedAtLastReport = played
            return .progress(position: position)
        }
        return nil
    }

    public func closing(position: Double) -> WatchEvent? {
        guard !disabled, qualified else { return nil }
        let finished = lengthSeconds > 0 && position >= lengthSeconds * Self.finishedFraction - 1e-9
        return .ended(position: position, finished: finished)
    }
}
