import Foundation

public enum QualityPreference: String, Codable, CaseIterable, Sendable {
    case auto, p1080, p720, p480, p360

    /// nil (no cap), 1080, 720, 480, 360.
    public var maxHeight: Int? {
        switch self {
        case .auto: return nil
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        }
    }

    /// "Auto", "1080p", "720p", "480p", "360p"
    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p360: return "360p"
        }
    }
}

/// All user-facing preferences. Stored as one JSON blob; unknown/missing keys decode to the defaults below.
public struct AppSettings: Codable, Hashable, Sendable {
    // Feed filters
    public var hideShorts = true
    public var hideMembersOnly = true
    public var hideLiveAndUpcoming = false
    public var hideWatchedInSubscriptions = false
    public var blockedChannels: [BlockedChannel] = []
    public var blockedKeywords: [String] = []

    // SponsorBlock and DeArrow
    public var sponsorBlockEnabled = true
    public var segmentBehaviors: [SponsorCategory: SegmentBehavior] = AppSettings.defaultSegmentBehaviors
    public var deArrowTitles = true

    // Playback
    public var wifiQuality: QualityPreference = .auto
    public var cellularQuality: QualityPreference = .p720
    public var defaultPlaybackRate: Double = 1.0
    public var autoplayNext = false
    public var backgroundPlayback = true
    public var autoPictureInPicture = true
    public var preferredCaptionLanguage: String? = nil

    // Account
    public var googleClientID: String = ""

    // Content language and region; nil means "use the device locale".
    public var contentLanguage: String? = nil
    public var contentRegion: String? = nil

    public init() {}

    /// Every key is optional: a missing key (older build, hand-edited file) takes its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        hideShorts = try c.decodeIfPresent(Bool.self, forKey: .hideShorts) ?? defaults.hideShorts
        hideMembersOnly = try c.decodeIfPresent(Bool.self, forKey: .hideMembersOnly) ?? defaults.hideMembersOnly
        hideLiveAndUpcoming = try c.decodeIfPresent(Bool.self, forKey: .hideLiveAndUpcoming) ?? defaults.hideLiveAndUpcoming
        hideWatchedInSubscriptions = try c.decodeIfPresent(Bool.self, forKey: .hideWatchedInSubscriptions)
            ?? defaults.hideWatchedInSubscriptions
        blockedChannels = try c.decodeIfPresent([BlockedChannel].self, forKey: .blockedChannels) ?? defaults.blockedChannels
        blockedKeywords = try c.decodeIfPresent([String].self, forKey: .blockedKeywords) ?? defaults.blockedKeywords
        sponsorBlockEnabled = try c.decodeIfPresent(Bool.self, forKey: .sponsorBlockEnabled) ?? defaults.sponsorBlockEnabled
        deArrowTitles = try c.decodeIfPresent(Bool.self, forKey: .deArrowTitles) ?? defaults.deArrowTitles
        wifiQuality = try c.decodeIfPresent(QualityPreference.self, forKey: .wifiQuality) ?? defaults.wifiQuality
        cellularQuality = try c.decodeIfPresent(QualityPreference.self, forKey: .cellularQuality) ?? defaults.cellularQuality
        defaultPlaybackRate = try c.decodeIfPresent(Double.self, forKey: .defaultPlaybackRate) ?? defaults.defaultPlaybackRate
        autoplayNext = try c.decodeIfPresent(Bool.self, forKey: .autoplayNext) ?? defaults.autoplayNext
        backgroundPlayback = try c.decodeIfPresent(Bool.self, forKey: .backgroundPlayback) ?? defaults.backgroundPlayback
        autoPictureInPicture = try c.decodeIfPresent(Bool.self, forKey: .autoPictureInPicture) ?? defaults.autoPictureInPicture
        preferredCaptionLanguage = try c.decodeIfPresent(String.self, forKey: .preferredCaptionLanguage)
        googleClientID = try c.decodeIfPresent(String.self, forKey: .googleClientID) ?? defaults.googleClientID
        contentLanguage = try c.decodeIfPresent(String.self, forKey: .contentLanguage)
        contentRegion = try c.decodeIfPresent(String.self, forKey: .contentRegion)

        // Behaviours are stored as {"sponsor": "autoSkip", ...}. Decode leniently so a category or behaviour
        // added or removed by another build never invalidates the whole file; categories not present in the
        // stored object keep their default behaviour.
        var behaviors = defaults.segmentBehaviors
        if let stored = try c.decodeIfPresent([String: String].self, forKey: .segmentBehaviors) {
            for (key, value) in stored {
                if let category = SponsorCategory(rawValue: key), let behavior = SegmentBehavior(rawValue: value) {
                    behaviors[category] = behavior
                }
            }
        }
        segmentBehaviors = behaviors
    }

    /// sponsor, selfpromo and interaction auto-skip; every other category shows in the bar.
    public static let defaultSegmentBehaviors: [SponsorCategory: SegmentBehavior] = {
        var behaviors: [SponsorCategory: SegmentBehavior] = [:]
        for category in SponsorCategory.allCases {
            switch category {
            case .sponsor, .selfpromo, .interaction: behaviors[category] = .autoSkip
            default: behaviors[category] = .showInBar
            }
        }
        return behaviors
    }()
}
