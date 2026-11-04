import Foundation

extension VideoSummary {
    /// This video with what it lacks taken from `details`, the same video as its watch page describes it.
    ///
    /// A link carries only a video id, so the player opens a bare summary (an empty title, no channel, no views) and
    /// completes it as it learns more: the resolved stream brings the title and the channel's name, the watch page brings
    /// the channel's picture and handle, the views and the age. What was there before is never replaced, so a title the
    /// stream already gave stays, and so does everything a list or the history knew when the video was opened from one.
    /// The history keeps the completed copy, which is why this runs at all: without it a video opened from a link would
    /// show up in the History list without its views and its age.
    ///
    /// Live and upcoming are not touched: the resolved stream decides those (see `settingLiveState`).
    public func filledIn(from details: VideoSummary) -> VideoSummary {
        guard details.id == id else { return self }
        var result = self

        if title.isBlank {
            result.title = details.title
        }
        result.channel = Self.completed(channel, from: details.channel)
        if thumbnails.isEmpty {
            result.thumbnails = details.thumbnails
        }
        if durationSeconds == nil {
            result.durationSeconds = details.durationSeconds
        }
        // The count and its text belong together: a copy that has either keeps both as they are.
        if viewCount == nil, viewCountText?.isBlank ?? true {
            result.viewCount = details.viewCount
            result.viewCountText = details.viewCountText
        }
        if publishedText?.isBlank ?? true {
            result.publishedText = details.publishedText
        }
        if publishedAt == nil {
            result.publishedAt = details.publishedAt
        }
        return result
    }

    /// `channel` with its empty parts filled from `other`, when `other` is the same channel; `other` itself when there
    /// is no channel yet. A page that names no channel (an empty id) adds nothing.
    private static func completed(_ channel: ChannelRef?, from other: ChannelRef?) -> ChannelRef? {
        guard let other, !other.id.isEmpty else { return channel }
        guard var channel else { return other }
        guard channel.id.isEmpty || channel.id == other.id else { return channel }

        if channel.id.isEmpty {
            channel.id = other.id
        }
        if channel.name.isBlank {
            channel.name = other.name
        }
        if channel.avatarURL == nil {
            channel.avatarURL = other.avatarURL
        }
        if channel.handle == nil {
            channel.handle = other.handle
        }
        return channel
    }
}

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
