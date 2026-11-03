import Foundation

/// Finds the chapter that contains a playback time.
public enum ChapterLookup {
    /// The chapter whose `startSeconds` is the latest one at or before `time`. Chapters need not be sorted. A time
    /// before the first chapter (or negative, or NaN) is in no chapter; a time past the last one is in the last.
    public static func chapter(at time: Double, in chapters: [Chapter]) -> Chapter? {
        var current: Chapter?
        for chapter in chapters where chapter.startSeconds.isFinite && chapter.startSeconds <= time {
            if let best = current, chapter.startSeconds < best.startSeconds { continue }
            current = chapter
        }
        return current
    }
}
