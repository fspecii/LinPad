import Foundation

/// Date arithmetic for the month, week and day views. Everything steps by calendar days,
/// never by 86 400 seconds, so daylight-saving days (23 or 25 hours) land on midnight.
enum CalendarMath {
    /// 6 weeks × 7 days from the first week start on or before the 1st of `date`'s month.
    static func monthGrid(for date: Date, calendar: Calendar) -> [Date] {
        let first = startOfMonth(date, calendar: calendar)
        let start = startOfWeek(first, calendar: calendar)
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func weekDays(containing date: Date, calendar: Calendar) -> [Date] {
        let start = startOfWeek(date, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    static func startOfMonth(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? calendar.startOfDay(for: date)
    }

    static func startOfWeek(_ date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    /// Midnight to the next midnight: 23, 24 or 25 hours.
    static func day(_ date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    static func month(_ date: Date, calendar: Calendar) -> DateInterval {
        let start = startOfMonth(date, calendar: calendar)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// The span a month grid shows, including the leading and trailing days.
    static func gridInterval(for date: Date, calendar: Calendar) -> DateInterval {
        let days = monthGrid(for: date, calendar: calendar)
        let start = days.first ?? date
        return DateInterval(start: start, end: day(days.last ?? date, calendar: calendar).end)
    }

    /// Week of year by the calendar's own rule (ISO 8601 in most of Europe, US-style elsewhere).
    static func weekNumber(of date: Date, calendar: Calendar) -> Int {
        calendar.component(.weekOfYear, from: date)
    }

    /// "M T W T F S S" starting from the calendar's first weekday.
    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    static func shortWeekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Hours since midnight, with the DST shift taken out: on the spring-forward day 03:00
    /// is 3, not 2, so the hour grid lines up with the clock.
    static func hourOffset(of date: Date, calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
    }

    /// `date` moved by `count` units of the view's period.
    static func step(_ date: Date, by count: Int, unit: Calendar.Component, calendar: Calendar) -> Date {
        calendar.date(byAdding: unit, value: count, to: date) ?? date
    }
}

/// Side-by-side columns for overlapping timed events in the day and week views.
enum EventColumns {
    struct Placement: Equatable {
        var column: Int
        var columnCount: Int
    }

    /// Events that overlap share a cluster; each gets the first column that is free at its
    /// start, and the whole cluster is divided into as many columns as it needed.
    static func layout(_ events: [CalendarEvent]) -> [String: Placement] {
        let sorted = events.sorted { ($0.start, $1.end) < ($1.start, $0.end) }
        var result: [String: Placement] = [:]
        var cluster: [(event: CalendarEvent, column: Int)] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let count = max(columnEnds.count, 1)
            for entry in cluster { result[entry.event.id] = Placement(column: entry.column, columnCount: count) }
            cluster = []
            columnEnds = []
        }

        for event in sorted {
            if event.start >= clusterEnd { flush() }
            let end = max(event.end, event.start.addingTimeInterval(15 * 60))
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[free] = end
                cluster.append((event, free))
            } else {
                columnEnds.append(end)
                cluster.append((event, columnEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, end)
        }
        flush()
        return result
    }
}
