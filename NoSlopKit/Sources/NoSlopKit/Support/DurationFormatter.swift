import Foundation

/// Formats a length in seconds the way YouTube shows it on a thumbnail badge.
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

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
