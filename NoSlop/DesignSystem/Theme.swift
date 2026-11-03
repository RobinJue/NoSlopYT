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
}
