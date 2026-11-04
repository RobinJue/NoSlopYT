import SwiftUI

/// The few constants every screen shares. Colours come from the asset catalog or from semantic system colours so
/// light and dark mode need no special cases.
enum Theme {
    /// The red accent: #E62117 in light mode, #FF4E45 in dark mode (the `AccentColor` asset).
    static let accent = Color("AccentColor")

    /// Standard horizontal/vertical spacing.
    static let padding: CGFloat = 12
    static let cornerRadius: CGFloat = 12

    /// Thumbnails are always 16:9.
    static let thumbnailAspectRatio: CGFloat = 16.0 / 9.0
    /// Width of the thumbnail in `VideoRowView` and `PlaylistRowView`.
    static let rowThumbnailWidth: CGFloat = 160
    /// Corner radius of row thumbnails and badges.
    static let thumbnailCornerRadius: CGFloat = 8
    /// Background of duration and status badges drawn over a thumbnail.
    static let badgeBackground = Color.black.opacity(0.8)

    // MARK: Feeds and headers

    /// Width of a card in the "Continue watching" row.
    static let continueWatchingCardWidth: CGFloat = 260
    /// A channel banner is about 6:1 (YouTube serves 2560 x 424).
    static let bannerAspectRatio: CGFloat = 6
    /// The narrowest a column of video cards may get before the feed switches to fewer, wider columns. A phone in
    /// portrait fits one column (edge to edge); an iPad or a phone in landscape fits two or three.
    static let feedColumnMinimumWidth: CGFloat = 340
    /// Space between cards in a feed, vertically and (when there are several columns) horizontally.
    static let feedSpacing: CGFloat = 20
    /// Fill of loading placeholders and of images that have not arrived yet.
    static let placeholderFill = Color(.secondarySystemFill)

    /// Extra room at the bottom of a scrolling screen while the mini player floats above the tab bar, so the last row
    /// can be scrolled clear of it. The mini player (`MiniPlayerView.height`, 64 pt) floats 58 pt above the bottom
    /// safe area where the tab bar is at the bottom, and 8 pt where it is at the top (an iPad in a regular-width
    /// window; see `MiniPlayerPlacement`, which also decides that for `PlayerOverlayContainer`). Measured on an
    /// iPhone 17 with the tab bar at the bottom: the top of the mini player is 156 pt above the bottom edge of the
    /// screen, while a scroll view already stops 83 pt above that edge (safe area and tab bar). 69 pt more, behind
    /// the `padding` every list ends with, leaves the last row 8 pt above the mini player. With the tab bar at the
    /// top the scroll view runs down to the safe area and the top of the mini player is 8 + 64 = 72 pt above that,
    /// one point less than the 73 pt it is above where the scroll view stops on an iPhone, so one value serves both
    /// placements.
    static let miniPlayerInset: CGFloat = 69
}
