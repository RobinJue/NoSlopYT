import Foundation

/// The list behind "Don't show this channel" and "Show this channel again" in the video menus, and behind Settings >
/// Feed filters > Blocked channels. A channel is known by its id; the name is only there to show in that list.
extension AppSettings {
    public func isBlocked(channelID: String) -> Bool {
        blockedChannels.contains { $0.id == channelID }
    }

    /// The blocked channel that `channel` is: by id, or, for a channel that came without one (YouTube's Home tiles), by
    /// the name or handle that was saved when it was blocked. The same rule `ContentFilter` hides videos by.
    public func blockedChannel(matching channel: ChannelRef) -> BlockedChannel? {
        if !channel.id.isEmpty { return blockedChannels.first { $0.id == channel.id } }
        let names = Set([channel.name, channel.handle ?? ""].map(ContentFilter.foldName).filter { !$0.isEmpty })
        guard !names.isEmpty else { return nil }
        return blockedChannels.first { blocked in
            !names.isDisjoint(with: [ContentFilter.foldName(blocked.name), ContentFilter.foldName(blocked.handle ?? "")].filter { !$0.isEmpty })
        }
    }

    /// Adds the channel to the blocked ones, at the end of the list.
    /// - Returns: false, and changes nothing, when the id is empty (there is nothing to recognise it by) or the channel
    ///   is blocked already.
    @discardableResult
    public mutating func blockChannel(id: String, name: String, handle: String? = nil) -> Bool {
        guard !id.isEmpty, !isBlocked(channelID: id) else { return false }
        blockedChannels.append(BlockedChannel(id: id, name: name, handle: handle))
        return true
    }

    /// Takes the channel off the list again, by id.
    /// - Returns: whether it was on it.
    @discardableResult
    public mutating func unblockChannel(id: String) -> Bool {
        guard isBlocked(channelID: id) else { return false }
        blockedChannels.removeAll { $0.id == id }
        return true
    }
}
