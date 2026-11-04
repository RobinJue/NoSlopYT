import Foundation

extension VideoSummary {
    /// The copy of this video that may go into a playlist or the download queue; nil while no title is known.
    ///
    /// A video opened from a link starts as a bare summary (an id and no title), and the player completes its own copy
    /// as the stream and the watch page answer (`PlayerController.complete(with:)`, `filledIn(from:)`). A sheet that was
    /// handed the bare copy when it opened saves from this instead: `player` is the player's copy, used when it is the
    /// same video, and whatever this copy already has is kept. A row saved without a title stays blank for good,
    /// because nothing completes a library entry later, so while neither copy has a title there is nothing to save.
    public func savableCopy(completedBy player: VideoSummary?) -> VideoSummary? {
        let completed = player.map { filledIn(from: $0) } ?? self
        return completed.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : completed
    }
}
