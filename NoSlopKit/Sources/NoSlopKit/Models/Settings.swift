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

    // YouTube recommendations (the optional TV connection)
    public var showYouTubeHome = true
    public var tellYouTubeAboutHiding = true
    public var sendWatchesToYouTube = true

    // Content language and region; nil means "use the device locale".
    public var contentLanguage: String? = nil
    public var contentRegion: String? = nil

    public init() {}

    /// Decodes every key on its own: a key that is missing, `null` or of the wrong type takes its default and the
    /// other keys keep what they say. One value that an older build, another build or a hand edit got wrong therefore
    /// never resets the rest of the settings. Only a document that is not an object at all throws.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        func read<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) -> Value {
            (try? c.decodeIfPresent(Value.self, forKey: key)) ?? fallback
        }

        hideShorts = read(.hideShorts, defaults.hideShorts)
        hideMembersOnly = read(.hideMembersOnly, defaults.hideMembersOnly)
        hideLiveAndUpcoming = read(.hideLiveAndUpcoming, defaults.hideLiveAndUpcoming)
        hideWatchedInSubscriptions = read(.hideWatchedInSubscriptions, defaults.hideWatchedInSubscriptions)
        sponsorBlockEnabled = read(.sponsorBlockEnabled, defaults.sponsorBlockEnabled)
        deArrowTitles = read(.deArrowTitles, defaults.deArrowTitles)
        wifiQuality = read(.wifiQuality, defaults.wifiQuality)
        cellularQuality = read(.cellularQuality, defaults.cellularQuality)
        defaultPlaybackRate = read(.defaultPlaybackRate, defaults.defaultPlaybackRate)
        autoplayNext = read(.autoplayNext, defaults.autoplayNext)
        backgroundPlayback = read(.backgroundPlayback, defaults.backgroundPlayback)
        autoPictureInPicture = read(.autoPictureInPicture, defaults.autoPictureInPicture)
        preferredCaptionLanguage = read(.preferredCaptionLanguage, defaults.preferredCaptionLanguage)
        googleClientID = read(.googleClientID, defaults.googleClientID)
        showYouTubeHome = read(.showYouTubeHome, defaults.showYouTubeHome)
        tellYouTubeAboutHiding = read(.tellYouTubeAboutHiding, defaults.tellYouTubeAboutHiding)
        sendWatchesToYouTube = read(.sendWatchesToYouTube, defaults.sendWatchesToYouTube)
        contentLanguage = read(.contentLanguage, defaults.contentLanguage)
        contentRegion = read(.contentRegion, defaults.contentRegion)

        // The two lists keep their readable entries: one broken entry must not unblock every other channel.
        blockedChannels = (try? c.decodeIfPresent([Lenient<BlockedChannel>].self, forKey: .blockedChannels))?
            .compactMap(\.value) ?? defaults.blockedChannels
        blockedKeywords = (try? c.decodeIfPresent([Lenient<String>].self, forKey: .blockedKeywords))?
            .compactMap(\.value) ?? defaults.blockedKeywords

        // Behaviours are stored as {"sponsor": "autoSkip", ...}. A category or behaviour added or removed by another
        // build, or an entry of the wrong type, is skipped; categories without a readable entry keep their default.
        var behaviors = defaults.segmentBehaviors
        if let stored = try? c.decodeIfPresent([String: Lenient<String>].self, forKey: .segmentBehaviors) {
            for (key, value) in stored {
                if let category = SponsorCategory(rawValue: key), let behavior = value.value.flatMap(SegmentBehavior.init(rawValue:)) {
                    behaviors[category] = behavior
                }
            }
        }
        segmentBehaviors = behaviors
    }

    /// A list or dictionary entry that decodes to nil instead of failing, so that its neighbours still decode.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: any Decoder) {
            value = try? Value(from: decoder)
        }
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
