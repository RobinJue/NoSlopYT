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
    /// The blocked channels' names and handles (folded, handles without "@"): for videos that come without a channel id.
    private let blockedChannelNames: Set<String>
    /// Keywords with case, diacritics and width folded away, blanks removed.
    private let blockedKeywords: [BlockedKeyword]
    /// The watched videos to hide in the subscriptions context; empty when the setting is off.
    private let hiddenWatchedIDs: Set<String>

    /// - Parameter watchedIDs: the videos the viewer has finished (only used when `hideWatchedInSubscriptions` is on).
    public init(settings: AppSettings, watchedIDs: Set<String> = []) {
        hideShorts = settings.hideShorts
        hideMembersOnly = settings.hideMembersOnly
        hideLiveAndUpcoming = settings.hideLiveAndUpcoming
        blockedChannelIDs = Set(settings.blockedChannels.map(\.id))
        blockedChannelNames = Set(settings.blockedChannels.flatMap { [Self.foldName($0.name), Self.foldName($0.handle ?? "")] }
            .filter { !$0.isEmpty })
        blockedKeywords = settings.blockedKeywords
            .map { Self.fold($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
            .map { BlockedKeyword(folded: $0) }
        hiddenWatchedIDs = settings.hideWatchedInSubscriptions ? watchedIDs : []
    }

    public func allows(_ video: VideoSummary, context: Context = .general) -> Bool {
        if hideShorts && video.isShort { return false }
        if hideMembersOnly && video.isMembersOnly { return false }
        if hideLiveAndUpcoming && (video.isLive || video.isUpcoming) { return false }
        if let channel = video.channel {
            if !channel.id.isEmpty {
                // A channel with an id is blocked by id only: another channel with the same name stays.
                if blockedChannelIDs.contains(channel.id) { return false }
            } else if isBlockedByName(channel) {
                return false
            }
        }
        if context == .subscriptions && hiddenWatchedIDs.contains(video.id) { return false }
        if !blockedKeywords.isEmpty {
            let title = Self.fold(video.title)
            if blockedKeywords.contains(where: { $0.matches(title) }) { return false }
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

    /// A video without a channel id (YouTube's Home tiles carry the name only) is recognised by name or handle.
    private func isBlockedByName(_ channel: ChannelRef) -> Bool {
        guard !blockedChannelNames.isEmpty else { return false }
        if blockedChannelNames.contains(Self.foldName(channel.name)) { return true }
        if let handle = channel.handle, blockedChannelNames.contains(Self.foldName(handle)) { return true }
        return false
    }

    /// Folded, trimmed, without a leading "@"; empty for a blank name.
    static func foldName(_ text: String) -> String {
        var folded = fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if folded.hasPrefix("@") { folded.removeFirst() }
        return folded
    }

    /// Lowercased, without accents and in half-width form, independent of the device locale.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// One blocked word or phrase, already folded (see `ContentFilter.fold`).
///
/// A keyword matches anywhere in a title ("minecraft" hides "Minecrafter" and "#Minecraft"), except a short one: of
/// one to three ASCII letters or digits ("AI", "ad", "vs", "4k"). Anywhere in a title those would hide ordinary
/// videos ("Rain Sounds", "Explained", "Again" all contain "ai"), so they match whole words only: the characters
/// before and after must not be ASCII letters or digits. The start and the end of the title, spaces, punctuation,
/// emoji and non-ASCII text (a CJK title has no spaces between its words) all count as the end of a word, so
/// "AI-generated", "ai: the future" and "AI技術" are matched too.
private struct BlockedKeyword: Sendable {
    let text: String
    let isWholeWordOnly: Bool

    init(folded text: String) {
        self.text = text
        isWholeWordOnly = text.count <= 3 && text.allSatisfy(Self.isWordCharacter)
    }

    /// `title` is folded the same way as the keyword.
    func matches(_ title: String) -> Bool {
        guard isWholeWordOnly else { return title.contains(text) }

        // Every occurrence is looked at, not just the first: "Rain, then AI" has the letters twice.
        var searchFrom = title.startIndex
        while let found = title.range(of: text, range: searchFrom..<title.endIndex) {
            let before = found.lowerBound > title.startIndex ? title[title.index(before: found.lowerBound)] : nil
            let after = found.upperBound < title.endIndex ? title[found.upperBound] : nil
            if !(before.map(Self.isWordCharacter) ?? false), !(after.map(Self.isWordCharacter) ?? false) {
                return true
            }
            searchFrom = title.index(after: found.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
