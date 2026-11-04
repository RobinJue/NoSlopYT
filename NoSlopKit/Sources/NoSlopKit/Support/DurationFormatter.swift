import Foundation

/// Formats a length in seconds the way YouTube shows it on a thumbnail badge (and in words, for VoiceOver).
public enum DurationFormatter {
    /// 5 → "0:05", 280 → "4:40", 3723 → "1:02:03". Negative input is treated as 0.
    public static func string(seconds: Int) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))"
        }
        return "\(minutes):\(twoDigits(secs))"
    }

    /// The length in words, for a screen reader: 200 → "3 minutes, 20 seconds", 3723 → "1 hour, 2 minutes, 3 seconds".
    /// Units that are zero are left out (180 → "3 minutes"). The badge text of `string(seconds:)` is read badly
    /// ("3:20" sounds like a time of day). Negative input is treated as 0.
    public static func spokenString(seconds: Int, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide)
        style.locale = locale
        return Duration.seconds(max(0, seconds)).formatted(style)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
