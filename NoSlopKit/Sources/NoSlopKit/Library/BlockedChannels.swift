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

extension ChannelRef {
    /// The channel to save when a tile that came without an id is blocked and its id was found on the watch page.
    /// The id and the handle come from the watch page; the name stays the one the tile shows, because an id-less tile is
    /// recognised by that name. When the watch page spells the name differently and gives no handle, its name is kept in
    /// the handle slot, so both spellings are recognised.
    public static func resolvedForBlocking(details: ChannelRef, tile: ChannelRef) -> ChannelRef {
        var resolved = details
        let tileName = tile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if tileName.isEmpty { return resolved }
        resolved.name = tile.name
        let detailsHandle = details.handle ?? tile.handle
        if let detailsHandle, !detailsHandle.isEmpty {
            resolved.handle = detailsHandle
        } else if ContentFilter.foldName(details.name) != ContentFilter.foldName(tile.name), !ContentFilter.foldName(details.name).isEmpty {
            resolved.handle = details.name
        } else {
            resolved.handle = nil
        }
        return resolved
    }
}
