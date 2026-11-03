import Foundation
import NoSlopKit

/// The watch history split into days, for the section headers of the History screen.
struct HistoryGroup: Identifiable {
    /// Midnight of the day.
    let id: Date
    /// "Today", "Yesterday", a weekday for the last week, otherwise the date.
    let title: String
    let entries: [HistoryEntry]
}

enum HistoryGrouping {
    /// Groups `entries` by the day they were last watched, keeping their order: the history is stored most recent
    /// first, so the groups come out newest first as well.
    static func groups(
        for entries: [HistoryEntry],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [HistoryGroup] {
        var days: [Date] = []
        var byDay: [Date: [HistoryEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.lastWatchedAt)
            if byDay[day] == nil {
                days.append(day)
            }
            byDay[day, default: []].append(entry)
        }
        return days.map { day in
            HistoryGroup(
                id: day,
                title: title(for: day, now: now, calendar: calendar, locale: locale),
                entries: byDay[day] ?? []
            )
        }
    }

    static func title(for day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? Int.max
        switch daysAgo {
        case 0:
            return "Today"
        case 1:
            return "Yesterday"
        case 2..<7:
            return day.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
        default:
            return day.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated).year())
        }
    }
}
