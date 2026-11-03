import Foundation

/// SponsorBlock segment categories. Raw values are the API's category names.
public enum SponsorCategory: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case sponsor, selfpromo, interaction, intro, outro, preview
    case musicOfftopic = "music_offtopic"
    case filler
    case poiHighlight = "poi_highlight"

    public var displayName: String {
        switch self {
        case .sponsor: return "Sponsor"
        case .selfpromo: return "Self-promotion"
        case .interaction: return "Interaction reminder"
        case .intro: return "Intro"
        case .outro: return "Outro"
        case .preview: return "Preview/recap"
        case .musicOfftopic: return "Non-music section"
        case .filler: return "Filler"
        case .poiHighlight: return "Highlight"
        }
    }

    /// SponsorBlock's own colour for the category, as "#RRGGBB".
    public var colorHex: String {
        switch self {
        case .sponsor: return "#00D400"
        case .selfpromo: return "#FFFF00"
        case .interaction: return "#CC00FF"
        case .intro: return "#00FFFF"
        case .outro: return "#0202ED"
        case .preview: return "#008FD6"
        case .musicOfftopic: return "#FF9900"
        case .filler: return "#7300FF"
        case .poiHighlight: return "#FF1684"
        }
    }
}

public enum SegmentActionType: String, Codable, Sendable {
    case skip, mute, poi, full, chapter
}

/// What the player does with segments of one category.
public enum SegmentBehavior: String, Codable, CaseIterable, Sendable {
    case autoSkip, showInBar, ignore
}

public struct SponsorSegment: Codable, Hashable, Sendable, Identifiable {
    /// SponsorBlock's segment UUID.
    public var id: String
    public var category: SponsorCategory
    public var actionType: SegmentActionType
    public var start: Double
    public var end: Double

    public init(id: String, category: SponsorCategory, actionType: SegmentActionType = .skip, start: Double, end: Double) {
        self.id = id
        self.category = category
        self.actionType = actionType
        self.start = start
        self.end = end
    }
}
