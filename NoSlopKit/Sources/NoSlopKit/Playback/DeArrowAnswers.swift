import Foundation

/// What the app remembers of DeArrow's answers for the session, so that a row scrolled back into view neither asks
/// again nor flickers from the original title to the community one.
///
/// Only an answer is remembered: a title, or "there is none". A lookup that failed (`DeArrowLookup.failed`: no
/// connection, a timeout, HTTP 429 or 5xx) is not an answer. Remembered as "none" it would keep the clickbait title on a
/// card until the app was killed, however often the connection came back.
///
/// A failure only keeps the video from being asked about again for `retryDelay`: a feed that scrolls through an outage
/// would otherwise send a new request, with a 15 s timeout, for every card that appears again. After that, or at once on
/// `forgetFailures()` (the connection is back, the setting was switched), the video is unknown again and the next
/// appearance asks.
///
/// A value type: the owner serialises access (the app keeps one on the main actor).
public struct DeArrowAnswers: Sendable {
    /// What is known about a video.
    public enum Recall: Equatable, Sendable {
        /// Never asked, or the last attempt failed and its wait is over: ask.
        case unknown
        /// DeArrow's answer: the community title, or nil for "there is none". Definitive.
        case answer(String?)
        /// The last attempt failed a moment ago: the original title shows and nobody asks yet.
        case waiting
    }

    /// How many answers are kept; the oldest go first.
    public static let defaultCapacity = 2_000
    /// How long a video that failed is left alone, in seconds.
    public static let defaultRetryDelay: TimeInterval = 60

    public let capacity: Int
    public let retryDelay: TimeInterval

    private struct Remembered {
        var title: String?
        /// Counts up with every answer recorded, so the oldest can be found.
        var sequence: Int
    }

    private let now: @Sendable () -> Date
    private var answers: [String: Remembered] = [:]
    /// When the last lookup of a video failed. Never holds a video that has an answer.
    private var failures: [String: Date] = [:]
    private var sequence = 0

    public init(
        capacity: Int = DeArrowAnswers.defaultCapacity,
        retryDelay: TimeInterval = DeArrowAnswers.defaultRetryDelay,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.capacity = max(1, capacity)
        self.retryDelay = max(0, retryDelay)
        self.now = now
    }

    /// What is known about the video right now.
    public func recall(_ videoID: String) -> Recall {
        if let remembered = answers[videoID] {
            return .answer(remembered.title)
        }
        if let failedAt = failures[videoID] {
            let elapsed = now().timeIntervalSince(failedAt)
            // A clock that went backwards must not leave a video waiting for hours.
            if elapsed >= 0, elapsed < retryDelay { return .waiting }
        }
        return .unknown
    }

    /// Remembers what a lookup came to. A title and "none" are answers; a failure is not, and never replaces one.
    public mutating func record(_ lookup: DeArrowLookup, for videoID: String) {
        switch lookup {
        case .title(let title):
            remember(title, for: videoID)
        case .none:
            remember(nil, for: videoID)
        case .failed:
            guard answers[videoID] == nil else { return }
            failures[videoID] = now()
            trimFailures()
        }
    }

    /// Ends the wait of every video that failed, so that the next appearance asks. Returns whether any was waiting.
    @discardableResult
    public mutating func forgetFailures() -> Bool {
        let hadFailures = !failures.isEmpty
        failures.removeAll()
        return hadFailures
    }

    // MARK: Bookkeeping

    private mutating func remember(_ title: String?, for videoID: String) {
        sequence += 1
        answers[videoID] = Remembered(title: title, sequence: sequence)
        failures[videoID] = nil
        while answers.count > capacity, let oldest = answers.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            answers[oldest] = nil
        }
    }

    /// Failures are only worth keeping while they wait, and no more than the answers are.
    private mutating func trimFailures() {
        guard failures.count > capacity else { return }
        let current = now()
        failures = failures.filter { current.timeIntervalSince($0.value) < retryDelay }
        while failures.count > capacity, let oldest = failures.min(by: { $0.value < $1.value })?.key {
            failures[oldest] = nil
        }
    }
}
