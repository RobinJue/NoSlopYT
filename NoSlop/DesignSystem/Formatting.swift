import Foundation
import NoSlopKit

/// Text helpers shared by the video cards and rows.
enum Formatting {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// "3 hours ago", "yesterday", "2 weeks ago" relative to now.
    static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// The second line under a video title: "Channel · 23M views · 11 years ago". Parts that are missing are left out.
    /// The age is YouTube's own text (`publishedText`), or a relative date computed from `publishedAt`.
    static func subtitle(for video: VideoSummary) -> String {
        var parts: [String] = []
        if let name = video.channel?.name, !name.isEmpty {
            parts.append(name)
        }
        if let stats = statsLine(for: video) {
            parts.append(stats)
        }
        return parts.joined(separator: " · ")
    }

    /// "23M views · 11 years ago": what follows the channel name when that has a line of its own (in a row).
    /// nil when neither is known.
    static func statsLine(for video: VideoSummary) -> String? {
        let parts = [viewsText(for: video), ageText(for: video)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "23M views": compact when the count is known, else YouTube's own text (for example "1,204 watching").
    static func viewsText(for video: VideoSummary) -> String? {
        if let count = video.viewCount {
            return compactViewCount(count)
        }
        guard let text = video.viewCountText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// "No views", "1 view", "999 views", "1.2K views", "23M views".
    static func compactViewCount(_ count: Int) -> String {
        switch count {
        case ..<1: return "No views"
        case 1: return "1 view"
        default: return "\(count.formatted(.number.notation(.compactName))) views"
        }
    }

    /// "11 years ago": YouTube's text when present, else a relative date from `publishedAt`.
    static func ageText(for video: VideoSummary) -> String? {
        if let text = video.publishedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        return video.publishedAt.map(relativeDate)
    }

    /// What is left of a video, rounded up to whole minutes: "Less than a minute left", "12 min left",
    /// "1 hr, 5 min left". nil when nothing is left (or the length is unknown, i.e. `seconds` is 0 or negative).
    static func timeLeft(seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        guard seconds >= 60 else { return "Less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        let text = Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        return "\(text) left"
    }

    /// "1 video", "14 videos".
    static func videoCountText(_ count: Int) -> String {
        count == 1 ? "1 video" : "\(count.formatted()) videos"
    }
}
