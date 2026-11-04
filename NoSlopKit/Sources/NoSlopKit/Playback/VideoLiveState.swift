import Foundation

extension VideoSummary {
    /// This video with the live state the player has learned, and no longer upcoming.
    ///
    /// A video reaches the player as a copy made earlier by a list: a Watch Later entry, a playlist item, a history row.
    /// A card saved while a broadcast was live still says live long after the broadcast became an ordinary video, and
    /// one saved as a premiere still says upcoming. The resolved stream (or the file on disk) is what is true now, so
    /// the player takes its word over the copy's, and the copy it writes to the history and to the lock screen with it.
    /// A stream that resolves is playing, so it is not upcoming either.
    public func settingLiveState(to isLive: Bool) -> VideoSummary {
        var settled = self
        settled.isLive = isLive
        settled.isUpcoming = false
        return settled
    }
}
