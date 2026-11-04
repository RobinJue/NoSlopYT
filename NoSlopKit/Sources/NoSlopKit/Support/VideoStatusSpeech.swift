import Foundation

/// What VoiceOver says about the badges on a video's thumbnail: how long it is (or that it is live, or not yet
/// started), how much of it was watched, and whether it is downloaded.
///
/// The thumbnail shows these as a badge ("3:20"), a red bar and an icon, which a screen reader cannot read in any
/// useful way ("3:20" sounds like a time of day).
public enum VideoStatusSpeech {
    /// One line such as "3 minutes, 20 seconds, 40 percent watched, Downloaded"; nil when there is nothing to say.
    ///
    /// - Parameters:
    ///   - isLive: a live stream says "Live" in place of a length; this wins over `isUpcoming`, as the badge does.
    ///   - isUpcoming: a premiere or stream that has not started says "Upcoming".
    ///   - durationSeconds: the length, spoken in words; zero or unknown says nothing.
    ///   - watchedFraction: how much was watched (0...1). Less than half a percent, and anything that is not a number,
    ///     says nothing.
    ///   - isDownloaded: the video is available offline.
    ///   - locale: the language of the words of the length.
    public static func status(
        isLive: Bool,
        isUpcoming: Bool,
        durationSeconds: Int?,
        watchedFraction: Double?,
        isDownloaded: Bool,
        locale: Locale = .autoupdatingCurrent
    ) -> String? {
        var parts: [String] = []

        if isLive {
            parts.append("Live")
        } else if isUpcoming {
            parts.append("Upcoming")
        } else if let seconds = durationSeconds, seconds > 0 {
            parts.append(DurationFormatter.spokenString(seconds: seconds, locale: locale))
        }

        if let fraction = watchedFraction, fraction.isFinite {
            let percent = Int((min(fraction, 1) * 100).rounded())
            if percent >= 1 {
                parts.append("\(percent) percent watched")
            }
        }

        if isDownloaded {
            parts.append("Downloaded")
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
