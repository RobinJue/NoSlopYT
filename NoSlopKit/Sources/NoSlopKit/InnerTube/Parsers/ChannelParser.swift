import Foundation

/// Parses `browse` responses for channel pages, channel tabs and their continuations.
///
/// STUB (Task 1A). Task 3 owns this file. `tabParams` is already final (it is part of the plan's interface), so
/// Task 2's facade can send the right `browse` params; the parse functions return nothing until Task 3 fills them in.
public enum ChannelParser {
    /// The `browse` `params` value that selects each channel tab.
    public static let tabParams: [ChannelTabKind: String] = [
        .videos: "EgZ2aWRlb3PyBgQKAjoA",
        .live: "EgdzdHJlYW1z8gYECgJ6AA%3D%3D",
        .playlists: "EglwbGF5bGlzdHPyBgoKCEIGCgIQaCIA",
    ]

    public static func parseChannelPage(_ json: JSON) -> ChannelPage? {
        nil
    }

    public static func parseTab(_ json: JSON) -> Page<SearchItem> {
        Page()
    }

    public static func parseContinuation(_ json: JSON) -> Page<SearchItem> {
        Page()
    }
}
