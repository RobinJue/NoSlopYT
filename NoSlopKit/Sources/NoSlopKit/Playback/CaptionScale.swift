import Foundation

/// How big the captions are drawn.
///
/// The usual sizes are small and meant for the video player they sit on: 14 pt inline and 22 pt in full screen, and a
/// compact step (12 and 16 pt) for a strip that cannot hold two lines of the usual one. Two preferences of the viewer
/// scale them: the relative size chosen in Settings > Accessibility > Subtitles & Captioning (the system offers 50 %
/// to 200 %), and the text size (Dynamic Type). Both multiply; the product is kept between half and two and a half
/// times, so that the captions neither vanish nor take over a small player (the caption view still drops them when
/// even the compact step does not fit between the controls).
public enum CaptionScale {
    /// The usual sizes come in two steps; `oneLine` captions use the compact one.
    public enum Tier: Sendable {
        case regular, compact
    }

    /// What the system lets the viewer pick as the relative character size.
    public static let systemSizeRange: ClosedRange<Double> = 0.5...2.0
    /// The text size stops following the viewer here: xxxLarge (23 pt body) against the usual Large (17 pt). Beyond
    /// it, accessibility sizes would make a caption that no strip of the player can hold.
    public static let largestDynamicTypeScale = 23.0 / 17.0
    /// What the two preferences together may make of the usual size.
    public static let totalRange: ClosedRange<Double> = 0.5...2.5

    /// The usual size in points, before the viewer's preferences.
    public static func baseSize(_ tier: Tier, isLarge: Bool) -> Double {
        switch tier {
        case .regular: isLarge ? 22 : 14
        case .compact: isLarge ? 16 : 12
        }
    }

    /// The factor for the usual sizes.
    ///
    /// - Parameters:
    ///   - systemRelativeSize: the relative character size of the viewer's caption style, nil when the system says the
    ///     content's own value wins (`useContentIfAvailable`): captions here have no style of their own, so the usual
    ///     size stays. Nonsense (zero, negative, not finite) counts as nil.
    ///   - dynamicTypeScale: the viewer's text size against the default one (1 at Large). A smaller text size does
    ///     not shrink the captions, and anything above `largestDynamicTypeScale` counts as that.
    public static func scale(systemRelativeSize: Double?, dynamicTypeScale: Double) -> Double {
        let system: Double
        if let value = systemRelativeSize, value.isFinite, value > 0 {
            system = min(max(value, systemSizeRange.lowerBound), systemSizeRange.upperBound)
        } else {
            system = 1
        }
        let dynamicType = dynamicTypeScale.isFinite ? min(max(dynamicTypeScale, 1), largestDynamicTypeScale) : 1
        return min(max(system * dynamicType, totalRange.lowerBound), totalRange.upperBound)
    }

    /// The font size in points: the usual size times `scale` (from `scale(systemRelativeSize:dynamicTypeScale:)`).
    public static func fontSize(_ tier: Tier, isLarge: Bool, scale: Double) -> Double {
        baseSize(tier, isLarge: isLarge) * scale
    }
}
