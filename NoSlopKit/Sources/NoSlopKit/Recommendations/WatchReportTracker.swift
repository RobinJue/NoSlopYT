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
    /// Where the media time that no report has covered yet began: the start of the current stretch of playing. A seek or a
    /// skip ends the stretch; a report moves the start to where it reached.
    private var segmentStart: Double?

    /// Where the range that the last event from `tick` or `flush` covers began (nil when unknown). The player hands it to
    /// the reporter with the event, so a resume at 10:00 reports 10:00 to 10:30, not 0 to 10:30.
    public private(set) var reportedFrom: Double?

    /// Where the range that `closing` at `position` covers began; right after a seek there is none, and it is empty.
    public func closingFrom(position: Double) -> Double { segmentStart ?? position }

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
        if let last = lastPosition {
            let step = position - last
            if isPlaying, step > 0, step <= Self.maxStep {
                played += step
                if segmentStart == nil { segmentStart = last }
            } else if step < 0 || step > Self.maxStep {
                // A seek or a skip: the stretch before it is over, a new one starts where playing goes on.
                segmentStart = nil
            }
        }
        if !qualified {
            let shortVideo = lengthSeconds > 0 && lengthSeconds < Self.qualifyingSeconds
            let reachedEnd = shortVideo && isPlaying && played > 0 && position >= lengthSeconds - 0.5
            if played >= Self.qualifyingSeconds - 1e-6 || reachedEnd {
                qualified = true
                playedAtLastReport = played
                markReported(at: position)
                return .qualified(position: position)
            }
            return nil
        }
        if played - playedAtLastReport >= Self.progressSeconds - 1e-6 {
            playedAtLastReport = played
            markReported(at: position)
            return .progress(position: position)
        }
        return nil
    }

    private mutating func markReported(at position: Double) {
        reportedFrom = segmentStart
        if segmentStart != nil { segmentStart = position }
    }

    /// The report for the range played so far, for the moments that are not the end of the viewing (the app goes to the
    /// background, where audio may play on). Nil until the viewing qualified. Unlike `closing`, it keeps the viewing
    /// open: later progress and the real end are still reported. Also nil when nothing new was played since the last
    /// report (right after a seek).
    public mutating func flush(position: Double) -> WatchEvent? {
        guard !disabled, qualified, segmentStart != nil else { return nil }
        playedAtLastReport = played
        markReported(at: position)
        return .progress(position: position)
    }

    public func closing(position: Double) -> WatchEvent? {
        guard !disabled, qualified else { return nil }
        let finished = lengthSeconds > 0 && position >= lengthSeconds * Self.finishedFraction - 1e-9
        return .ended(position: position, finished: finished)
    }
}
