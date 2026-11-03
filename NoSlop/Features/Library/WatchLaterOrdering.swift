import Foundation
import NoSlopKit

/// Puts the Watch Later list in a new order.
///
/// `LibraryStore` has no "move" operation: `toggleWatchLater` adds a video at the top of the list or removes it.
/// This rebuilds the list from those two operations. Everything happens in one synchronous pass on the main actor,
/// so the screen only ever sees the final order. (A `moveWatchLater(fromOffsets:toOffset:)` on the store would
/// replace this; it is listed as a contract change request.)
enum WatchLaterOrdering {
    /// Makes the list read exactly `ordered`. Does nothing when it already does.
    static func apply(_ ordered: [VideoSummary], to library: LibraryStore) {
        let wanted = ordered.map(\.id)
        guard library.watchLater.map(\.id) != wanted else { return }

        // New videos go on top, so adding them last-to-first leaves the first one on top.
        rebuild(from: ordered.reversed(), in: library)
        if library.watchLater.map(\.id) == wanted { return }

        // A store that appends instead of inserting on top needs them in order.
        rebuild(from: ordered, in: library)
    }

    private static func rebuild(from videos: some Sequence<VideoSummary>, in library: LibraryStore) {
        // `watchLater` is read once: this loop works on a copy while the store changes.
        for saved in library.watchLater {
            library.toggleWatchLater(saved)
        }
        for video in videos {
            library.toggleWatchLater(video)
        }
    }
}
