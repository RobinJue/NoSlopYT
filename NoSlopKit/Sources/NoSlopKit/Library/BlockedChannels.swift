import Foundation

/// The list behind "Don't show this channel" and "Show this channel again" in the video menus, and behind Settings >
/// Feed filters > Blocked channels. A channel is known by its id; the name is only there to show in that list.
extension AppSettings {
    public func isBlocked(channelID: String) -> Bool {
        blockedChannels.contains { $0.id == channelID }
    }

    /// Adds the channel to the blocked ones, at the end of the list.
    /// - Returns: false, and changes nothing, when the id is empty (there is nothing to recognise it by) or the channel
    ///   is blocked already.
    @discardableResult
    public mutating func blockChannel(id: String, name: String) -> Bool {
        guard !id.isEmpty, !isBlocked(channelID: id) else { return false }
        blockedChannels.append(BlockedChannel(id: id, name: name))
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
