import Foundation

/// Applies the user's feed filters (Shorts, members-only, live/upcoming, watched, blocked channels and keywords).
///
/// STUB (Task 1A). Task 6 owns this file. The stub filters nothing: `allows` is always true and the `filter`
/// functions return their input unchanged, so screens built against it still show data.
public struct ContentFilter: Sendable {
    public enum Context: Sendable {
        case general
        case subscriptions
    }

    public init(settings: AppSettings, watchedIDs: Set<String> = []) {}

    public func allows(_ video: VideoSummary, context: Context = .general) -> Bool {
        true
    }

    public func filter(_ videos: [VideoSummary], context: Context = .general) -> [VideoSummary] {
        videos
    }

    public func filter(_ items: [SearchItem]) -> [SearchItem] {
        items
    }
}
