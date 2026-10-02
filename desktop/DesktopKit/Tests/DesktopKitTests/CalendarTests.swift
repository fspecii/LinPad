import XCTest
@testable import DesktopKit

final class CalendarMathTests: XCTestCase {
    private func calendar(firstWeekday: Int, zone: String = "Europe/London", iso: Bool = false) -> Calendar {
        var calendar = Calendar(identifier: iso ? .iso8601 : .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = firstWeekday
        if iso { calendar.minimumDaysInFirstWeek = 4 }
        return calendar
    }

    private func date(_ text: String, _ calendar: Calendar) -> Date {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts.count > 3 ? parts[3] : 0))!
    }

    func testMonthGridStartsOnTheCalendarsFirstWeekday() {
        // 1 October 2026 is a Thursday.
        let sunday = calendar(firstWeekday: 1)
        let monday = calendar(firstWeekday: 2)
        let sundayGrid = CalendarMath.monthGrid(for: date("2026-10-15", sunday), calendar: sunday)
        let mondayGrid = CalendarMath.monthGrid(for: date("2026-10-15", monday), calendar: monday)
        XCTAssertEqual(sundayGrid.count, 42)
        XCTAssertEqual(sundayGrid.first, date("2026-09-27", sunday))
        XCTAssertEqual(mondayGrid.first, date("2026-09-28", monday))
        XCTAssertEqual(CalendarMath.weekdaySymbols(calendar: monday).first, monday.veryShortStandaloneWeekdaySymbols[1])
    }

    func testAMonthStartingOnTheFirstWeekdayHasNoLeadingDays() {
        // 1 June 2026 is a Monday.
        let monday = calendar(firstWeekday: 2)
        XCTAssertEqual(CalendarMath.monthGrid(for: date("2026-06-20", monday), calendar: monday).first, date("2026-06-01", monday))
    }

    func testEveryGridDayIsMidnightAcrossDaylightSavingChanges() {
        let london = calendar(firstWeekday: 2)
        for month in ["2026-03-10", "2026-10-10"] {
            let days = CalendarMath.monthGrid(for: date(month, london), calendar: london)
            for day in days {
                XCTAssertEqual(london.component(.hour, from: day), 0, "\(day)")
            }
            XCTAssertEqual(Set(days).count, 42)
        }
    }

    func testDaylightSavingDaysAreTwentyThreeAndTwentyFiveHoursLong() {
        let london = calendar(firstWeekday: 2)
        XCTAssertEqual(CalendarMath.day(date("2026-03-29", london), calendar: london).duration, 23 * 3600)
        XCTAssertEqual(CalendarMath.day(date("2026-10-25", london), calendar: london).duration, 25 * 3600)
        XCTAssertEqual(CalendarMath.day(date("2026-10-26", london), calendar: london).duration, 24 * 3600)
        let us = calendar(firstWeekday: 1, zone: "America/New_York")
        XCTAssertEqual(CalendarMath.day(date("2026-03-08", us), calendar: us).duration, 23 * 3600)
    }

    func testHourOffsetFollowsTheWallClockOnTheSpringForwardDay() {
        let london = calendar(firstWeekday: 2)
        let threeAM = date("2026-03-29-3", london)
        XCTAssertEqual(CalendarMath.hourOffset(of: threeAM, calendar: london), 3)
    }

    func testWeekNumbersFollowISO8601() {
        let iso = calendar(firstWeekday: 2, iso: true)
        XCTAssertEqual(CalendarMath.weekNumber(of: date("2021-01-01", iso), calendar: iso), 53)
        XCTAssertEqual(CalendarMath.weekNumber(of: date("2026-01-01", iso), calendar: iso), 1)
        XCTAssertEqual(CalendarMath.weekNumber(of: date("2026-10-02", iso), calendar: iso), 40)
    }

    func testWeekDaysStepThroughTheDaylightSavingWeek() {
        let london = calendar(firstWeekday: 2)
        let week = CalendarMath.weekDays(containing: date("2026-10-25", london), calendar: london)
        XCTAssertEqual(week.first, date("2026-10-19", london))
        XCTAssertEqual(week.last, date("2026-10-25", london))
    }

    func testOverlappingEventsShareColumns() {
        let london = calendar(firstWeekday: 2)
        func event(_ id: String, _ start: Int, _ end: Int) -> CalendarEvent {
            CalendarEvent(id: id, title: id, start: date("2026-10-02-\(start)", london),
                          end: date("2026-10-02-\(end)", london), calendarID: "c")
        }
        let layout = EventColumns.layout([event("a", 9, 11), event("b", 10, 12), event("c", 11, 13), event("d", 14, 15)])
        XCTAssertEqual(layout["a"], .init(column: 0, columnCount: 2))
        XCTAssertEqual(layout["b"], .init(column: 1, columnCount: 2))
        XCTAssertEqual(layout["c"], .init(column: 0, columnCount: 2))
        XCTAssertEqual(layout["d"], .init(column: 0, columnCount: 1))
    }
}

@MainActor
final class CalendarStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-\(UUID().uuidString).json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testLocalStoreKeepsEventsAcrossLaunches() {
        let store = CalendarStore(bundle: Bundle(for: Self.self), local: LocalCalendarBackend(fileURL: fileURL, schedulesAlerts: false))
        XCTAssertEqual(store.access, .unavailable)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var event = CalendarEvent(title: "Dentist", start: start, end: start.addingTimeInterval(1800),
                                  calendarID: store.defaultCalendarID ?? "")
        XCTAssertTrue(store.save(event))
        event.title = "Dentist (moved)"
        XCTAssertTrue(store.save(event))

        let reopened = CalendarStore(bundle: Bundle(for: Self.self), local: LocalCalendarBackend(fileURL: fileURL, schedulesAlerts: false))
        let found = reopened.events(in: DateInterval(start: start.addingTimeInterval(-60), duration: 3600))
        XCTAssertEqual(found.map(\.title), ["Dentist (moved)"])
        reopened.delete(found[0])
        XCTAssertTrue(reopened.events(in: DateInterval(start: start, duration: 3600)).isEmpty)
    }

    func testHiddenCalendarsAreFilteredOut() {
        let store = CalendarStore(bundle: Bundle(for: Self.self), local: LocalCalendarBackend(fileURL: fileURL, schedulesAlerts: false))
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        store.save(CalendarEvent(title: "Standup", start: start, end: start.addingTimeInterval(900), calendarID: "local.work"))
        let span = DateInterval(start: start, duration: 3600)
        XCTAssertEqual(store.events(in: span).count, 1)
        store.toggleVisibility("local.work")
        defer { store.toggleVisibility("local.work") }
        XCTAssertTrue(store.events(in: span).isEmpty)
    }

    func testICSExportEscapesFoldsAndUsesFloatingDatesForAllDayEvents() {
        var london = Calendar(identifier: .gregorian)
        london.timeZone = .current
        let day = london.date(from: DateComponents(year: 2026, month: 12, day: 24))!
        let events = [
            CalendarEvent(id: "x", title: "Dinner; with friends, maybe", start: Date(timeIntervalSince1970: 1_790_000_000),
                          end: Date(timeIntervalSince1970: 1_790_003_600), calendarID: "c", notes: "Line 1\nLine 2",
                          alertMinutes: 15),
            CalendarEvent(id: "y", title: "Christmas Eve", start: day, end: london.date(byAdding: .day, value: 1, to: day)!,
                          isAllDay: true, calendarID: "c"),
        ]
        let text = ICSWriter.document(events, calendars: [CalendarInfo(id: "c", title: "Home", colorHex: "#ff0000")],
                                      now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(text.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(text.contains("SUMMARY:Dinner\\; with friends\\, maybe\r\n"))
        XCTAssertTrue(text.contains("DESCRIPTION:Line 1\\nLine 2\r\n"))
        XCTAssertTrue(text.contains("DTSTART:20260921T"))
        XCTAssertTrue(text.contains("TRIGGER:-PT15M"))
        XCTAssertTrue(text.contains("DTSTART;VALUE=DATE:20261224\r\nDTEND;VALUE=DATE:20261225"))
        XCTAssertTrue(text.contains("CATEGORIES:Home"))
        for line in text.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 75)
        }
        let long = ICSWriter.fold("SUMMARY:" + String(repeating: "é", count: 60))
        XCTAssertTrue(long.contains("\r\n "))
        XCTAssertEqual(long.replacingOccurrences(of: "\r\n ", with: ""), "SUMMARY:" + String(repeating: "é", count: 60))
    }

    func testICSExportWritesIntoTheGuestHome() async throws {
        let host = MockLinuxHost(latency: .zero)
        let store = CalendarStore(bundle: Bundle(for: Self.self), local: LocalCalendarBackend(fileURL: fileURL, schedulesAlerts: false))
        store.save(CalendarEvent(title: "Release", start: Date().addingTimeInterval(3600), end: Date().addingTimeInterval(7200),
                                 calendarID: "local.personal"))
        let error = await store.exportICS(to: host)
        XCTAssertNil(error)
        let data = try await host.readFile("/root/Calendar/linpad.ics")
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("SUMMARY:Release"))
    }
}
