import Foundation

/// YouTube's relative ages ("3 days ago", "Streamed 2 months ago", "13d ago") read back as the date they stand for.
///
/// The text is only true on the day YouTube wrote it: kept, it reads "3 days ago" for ever. A date does not age.
/// English only. Every other language, and every text that is not an age (a date still to come: "Scheduled for ...",
/// a viewer count), gives nil, and the caller shows no age rather than a wrong one. The length of a month (30 days)
/// and of a year (365) are the usual round figures: YouTube rounds, too ("11 months ago" is 11 to 12 months).
enum RelativeAge {
    /// The date `text` says it is, counted back from `reference`: the day the text was read.
    static func date(from text: String, relativeTo reference: Date) -> Date? {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2, words.last == "ago" else { return nil }
        let rest = Array(words.dropLast())

        // The amount, in two words ("3 days") or glued together ("13d", "2mo"), and how many words it took.
        let amount: Int
        let unit: String
        let used: Int
        if let last = rest.last, let compact = compactAmount(last) {
            (amount, unit, used) = (compact.amount, compact.unit, 1)
        } else if rest.count >= 2, let number = number(rest[rest.count - 2]) {
            (amount, unit, used) = (number, rest[rest.count - 1], 2)
        } else {
            return nil
        }
        guard let seconds = unitSeconds[unit] else { return nil }

        // What stands before the amount may only be a word that introduces an age: "Streamed 5 days ago".
        guard introductions.contains(rest.dropLast(used).joined(separator: " ")) else { return nil }
        return reference.addingTimeInterval(-TimeInterval(amount) * seconds)
    }

    private static let introductions: Set<String> = ["", "streamed", "premiered", "started streaming"]

    private static let unitSeconds: [String: TimeInterval] = [
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3_600, "hr": 3_600, "hrs": 3_600, "hour": 3_600, "hours": 3_600,
        "d": 86_400, "day": 86_400, "days": 86_400,
        "w": 604_800, "wk": 604_800, "wks": 604_800, "week": 604_800, "weeks": 604_800,
        "mo": 2_592_000, "mos": 2_592_000, "month": 2_592_000, "months": 2_592_000,
        "y": 31_536_000, "yr": 31_536_000, "yrs": 31_536_000, "year": 31_536_000, "years": 31_536_000,
    ]

    /// A whole number of up to six ASCII digits; anything longer is no age (and could overflow).
    private static func number(_ word: String) -> Int? {
        guard (1...6).contains(word.count), word.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(word)
    }

    /// "13d" -> (13, "d"), "2mo" -> (2, "mo").
    private static func compactAmount(_ word: String) -> (amount: Int, unit: String)? {
        let digits = word.prefix { $0.isASCII && $0.isNumber }
        let unit = word.dropFirst(digits.count)
        guard !unit.isEmpty, let amount = number(String(digits)) else { return nil }
        return (amount, String(unit))
    }
}

extension VideoSummary {
    /// The video as the library keeps it: without what was only true on the day it was saved.
    ///
    /// - The age. The relative text ("3 days ago") is replaced by a date counted back from `savedAt`, which the
    ///   screens turn into a fresh age every time (`Formatting.ageText` shows `publishedAt` when there is no text). A
    ///   date the video already has (RSS and Data API items) is kept. Text that cannot be read (another language), or
    ///   any text when the day of saving is not known, leaves no age at all.
    /// - Live and upcoming. A stream that was live or a premiere that was upcoming when it was saved is neither by
    ///   the time it is opened; the player finds out again from the stream itself. The count of people watching or
    ///   waiting goes with the marks ("1,204 watching" is not a view count). A scheduled start stays a date.
    func forLibrary(savedAt: Date?) -> VideoSummary {
        guard publishedText != nil || isLive || isUpcoming else { return self }
        var video = self
        if video.publishedAt == nil, let savedAt, let text = video.publishedText {
            video.publishedAt = RelativeAge.date(from: text, relativeTo: savedAt)
        }
        video.publishedText = nil
        if video.isLive || video.isUpcoming {
            // For a live video a number that is not a total ("1,204 watching", or any text a count was not read from)
            // counts the people there at that moment. A real total, if one is known, stays.
            if video.viewCount == nil || Self.countsPeopleNow(video.viewCountText) {
                video.viewCount = nil
                video.viewCountText = nil
            }
            video.isLive = false
            video.isUpcoming = false
        }
        return video
    }

    private static func countsPeopleNow(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.lowercased().split(whereSeparator: { !$0.isLetter }).contains { $0 == "watching" || $0 == "waiting" }
    }
}
