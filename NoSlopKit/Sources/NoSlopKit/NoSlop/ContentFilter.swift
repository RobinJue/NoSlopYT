import Foundation

/// Applies the user's feed filters (Shorts, members-only, live/upcoming, watched, blocked channels and keywords).
///
/// A filter is a snapshot of the settings: build one per refresh (`AppEnvironment.contentFilter`) and use it for the
/// whole list rather than once per row.
public struct ContentFilter: Sendable {
    public enum Context: Sendable {
        /// Home, search, channels, playlists: everywhere that is not the subscriptions feed.
        case general
        /// The subscriptions feed, where "hide watched videos" applies.
        case subscriptions
    }

    private let hideShorts: Bool
    private let hideMembersOnly: Bool
    private let hideLiveAndUpcoming: Bool
    private let blockedChannelIDs: Set<String>
    /// Keywords with case, diacritics and width folded away, blanks removed.
    private let blockedKeywords: [String]
    /// The watched videos to hide in the subscriptions context; empty when the setting is off.
    private let hiddenWatchedIDs: Set<String>

    /// - Parameter watchedIDs: the videos the viewer has finished (only used when `hideWatchedInSubscriptions` is on).
    public init(settings: AppSettings, watchedIDs: Set<String> = []) {
        hideShorts = settings.hideShorts
        hideMembersOnly = settings.hideMembersOnly
        hideLiveAndUpcoming = settings.hideLiveAndUpcoming
        blockedChannelIDs = Set(settings.blockedChannels.map(\.id))
        blockedKeywords = settings.blockedKeywords
            .map { Self.fold($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
        hiddenWatchedIDs = settings.hideWatchedInSubscriptions ? watchedIDs : []
    }

    public func allows(_ video: VideoSummary, context: Context = .general) -> Bool {
        if hideShorts && video.isShort { return false }
        if hideMembersOnly && video.isMembersOnly { return false }
        if hideLiveAndUpcoming && (video.isLive || video.isUpcoming) { return false }
        if let channelID = video.channel?.id, blockedChannelIDs.contains(channelID) { return false }
        if context == .subscriptions && hiddenWatchedIDs.contains(video.id) { return false }
        if !blockedKeywords.isEmpty {
            let title = Self.fold(video.title)
            if blockedKeywords.contains(where: { title.contains($0) }) { return false }
        }
        return true
    }

    public func filter(_ videos: [VideoSummary], context: Context = .general) -> [VideoSummary] {
        videos.filter { allows($0, context: context) }
    }

    /// Search results: videos follow the video rules; blocked channels and the playlists they own are dropped.
    public func filter(_ items: [SearchItem]) -> [SearchItem] {
        items.filter { item in
            switch item {
            case .video(let video):
                return allows(video)
            case .channel(let channel):
                return !blockedChannelIDs.contains(channel.id)
            case .playlist(let playlist):
                guard let ownerID = playlist.channel?.id else { return true }
                return !blockedChannelIDs.contains(ownerID)
            }
        }
    }

    /// Lowercased, without accents and in half-width form, independent of the device locale.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
