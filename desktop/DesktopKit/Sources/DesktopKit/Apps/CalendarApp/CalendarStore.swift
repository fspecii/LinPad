import EventKit
import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// One occurrence of an event. Recurring events from EventKit appear once per occurrence,
/// each with its own `id`; `sourceID` names the series.
struct CalendarEvent: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var sourceID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var calendarID: String
    var location: String
    var notes: String
    /// Minutes before the start for the reminder alert; nil for none.
    var alertMinutes: Int?
    var isRecurring = false

    init(id: String = UUID().uuidString, sourceID: String? = nil, title: String, start: Date, end: Date,
         isAllDay: Bool = false, calendarID: String, location: String = "", notes: String = "",
         alertMinutes: Int? = nil, isRecurring: Bool = false) {
        self.id = id
        self.sourceID = sourceID ?? id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.location = location
        self.notes = notes
        self.alertMinutes = alertMinutes
        self.isRecurring = isRecurring
    }

    func overlaps(_ interval: DateInterval) -> Bool {
        start < interval.end && max(end, start.addingTimeInterval(1)) > interval.start
    }
}

struct CalendarInfo: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var title: String
    /// `#rrggbb`.
    var colorHex: String
    var isEditable = true
    /// The account it belongs to ("iCloud", "Gmail", "On My iPad").
    var account = ""

    var color: Color { RGB(hex: colorHex)?.color ?? .accentColor }
}

/// Where events live: the iPad's calendars through EventKit, or a local file when the user
/// has not given LinPad calendar access.
@MainActor
protocol CalendarBackend: AnyObject {
    var calendars: [CalendarInfo] { get }
    var defaultCalendarID: String? { get }
    func events(in interval: DateInterval) -> [CalendarEvent]
    @discardableResult func save(_ event: CalendarEvent) throws -> CalendarEvent
    func delete(_ event: CalendarEvent) throws
}

// MARK: - EventKit

@MainActor
final class EventKitCalendarBackend: CalendarBackend {
    let store: EKEventStore
    /// Fetched occurrences by `CalendarEvent.id`, so edits reach the exact occurrence.
    private var fetched: [String: EKEvent] = [:]

    init(store: EKEventStore) {
        self.store = store
    }

    var calendars: [CalendarInfo] {
        store.calendars(for: .event).map { calendar in
            CalendarInfo(id: calendar.calendarIdentifier, title: calendar.title,
                         colorHex: RGB(uiColor: UIColor(cgColor: calendar.cgColor)).hex,
                         isEditable: calendar.allowsContentModifications, account: calendar.source.title)
        }
    }

    var defaultCalendarID: String? { store.defaultCalendarForNewEvents?.calendarIdentifier }

    func events(in interval: DateInterval) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        return store.events(matching: predicate).map { event in
            let id = Self.occurrenceID(event)
            fetched[id] = event
            let alert = event.alarms?.first.map { Int((-$0.relativeOffset / 60).rounded()) }
            return CalendarEvent(id: id, sourceID: event.eventIdentifier ?? id, title: event.title ?? "",
                                 start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                                 calendarID: event.calendar.calendarIdentifier, location: event.location ?? "",
                                 notes: event.notes ?? "", alertMinutes: alert, isRecurring: event.hasRecurrenceRules)
        }
    }

    @discardableResult
    func save(_ event: CalendarEvent) throws -> CalendarEvent {
        let target = fetched[event.id] ?? EKEvent(eventStore: store)
        target.title = event.title
        target.startDate = event.start
        target.endDate = event.end
        target.isAllDay = event.isAllDay
        target.location = event.location.isEmpty ? nil : event.location
        target.notes = event.notes.isEmpty ? nil : event.notes
        target.calendar = store.calendar(withIdentifier: event.calendarID) ?? store.defaultCalendarForNewEvents
        target.alarms = event.alertMinutes.map { [EKAlarm(relativeOffset: -Double($0) * 60)] }
        try store.save(target, span: .thisEvent, commit: true)
        var saved = event
        saved.id = Self.occurrenceID(target)
        saved.sourceID = target.eventIdentifier ?? saved.id
        fetched[saved.id] = target
        return saved
    }

    func delete(_ event: CalendarEvent) throws {
        guard let target = fetched[event.id] ?? store.event(withIdentifier: event.sourceID) else { return }
        try store.remove(target, span: .thisEvent, commit: true)
        fetched[event.id] = nil
    }

    private static func occurrenceID(_ event: EKEvent) -> String {
        "\(event.eventIdentifier ?? UUID().uuidString)@\(Int(event.startDate.timeIntervalSince1970))"
    }
}

private extension RGB {
    init(uiColor: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(min(max(red, 0), 1)), green: Double(min(max(green, 0), 1)), blue: Double(min(max(blue, 0), 1)))
    }
}

// MARK: - Local

/// Events kept in a JSON file inside the app, for when calendar access is denied or the
/// build has no calendar usage description (the UI-test harness).
@MainActor
final class LocalCalendarBackend: CalendarBackend {
    private struct Contents: Codable {
        var calendars: [CalendarInfo]
        var events: [CalendarEvent]
    }

    static let defaultCalendars = [
        CalendarInfo(id: "local.personal", title: "Personal", colorHex: "#4f8ff7", account: "On This iPad"),
        CalendarInfo(id: "local.work", title: "Work", colorHex: "#f2994a", account: "On This iPad"),
    ]

    private let fileURL: URL
    private var contents: Contents
    /// Off in unit tests, whose host process has no app bundle for notifications.
    private let schedulesAlerts: Bool

    init(fileURL: URL = LocalCalendarBackend.defaultFileURL, schedulesAlerts: Bool = true) {
        self.fileURL = fileURL
        self.schedulesAlerts = schedulesAlerts
        contents = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) }
            ?? Contents(calendars: Self.defaultCalendars, events: [])
    }

    nonisolated static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Calendar/events.json")
    }

    var calendars: [CalendarInfo] { contents.calendars }
    var defaultCalendarID: String? { contents.calendars.first?.id }

    func events(in interval: DateInterval) -> [CalendarEvent] {
        contents.events.filter { $0.overlaps(interval) }.sorted { $0.start < $1.start }
    }

    @discardableResult
    func save(_ event: CalendarEvent) throws -> CalendarEvent {
        if let index = contents.events.firstIndex(where: { $0.id == event.id }) {
            contents.events[index] = event
        } else {
            contents.events.append(event)
        }
        try write()
        scheduleAlert(for: event)
        return event
    }

    func delete(_ event: CalendarEvent) throws {
        contents.events.removeAll { $0.id == event.id }
        try write()
        if schedulesAlerts {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [event.id])
        }
    }

    private func write() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(contents).write(to: fileURL, options: .atomic)
    }

    /// EventKit alerts fire on their own; local events need a notification of their own.
    private func scheduleAlert(for event: CalendarEvent) {
        guard schedulesAlerts else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [event.id])
        guard let minutes = event.alertMinutes else { return }
        let fireDate = event.start.addingTimeInterval(-Double(minutes) * 60)
        guard fireDate > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title.isEmpty ? "Event" : event.title
        content.body = event.start.formatted(date: .omitted, time: .shortened)
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let request = UNNotificationRequest(identifier: event.id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }
}

// MARK: - Store

/// The calendar the panel popover, the Calendar app and the widgets share.
@Observable @MainActor
final class CalendarStore {
    enum Access: Equatable {
        /// Not asked yet; local events until the user turns iPad calendars on.
        case notDetermined
        case granted
        case denied
        /// This build cannot ask (no NSCalendarsFullAccessUsageDescription).
        case unavailable
    }

    static let hiddenCalendarsKey = "calendar.hiddenCalendars"
    static let usageDescriptionKey = "NSCalendarsFullAccessUsageDescription"

    private(set) var access: Access
    private(set) var calendars: [CalendarInfo] = []
    /// Bumped on every change, so views that fetch events recompute.
    private(set) var revision = 0
    var hiddenCalendarIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: CalendarStore.hiddenCalendarsKey) ?? []) {
        didSet { UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: Self.hiddenCalendarsKey) }
    }
    private(set) var lastError: String?

    @ObservationIgnored private var backend: any CalendarBackend
    @ObservationIgnored private let eventStore: EKEventStore?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    /// Fetches by interval for the current revision; views ask for the same span many times.
    @ObservationIgnored private var cache: [DateInterval: [CalendarEvent]] = [:]

    init(bundle: Bundle = .main, local: LocalCalendarBackend? = nil) {
        let canAsk = bundle.object(forInfoDictionaryKey: Self.usageDescriptionKey) != nil
        let localBackend = local ?? LocalCalendarBackend()
        guard canAsk else {
            access = .unavailable
            eventStore = nil
            backend = localBackend
            calendars = localBackend.calendars
            return
        }
        let store = EKEventStore()
        eventStore = store
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            access = .granted
            backend = EventKitCalendarBackend(store: store)
        case .notDetermined:
            access = .notDetermined
            backend = localBackend
        default:
            access = .denied
            backend = localBackend
        }
        calendars = backend.calendars
        observeChanges()
    }

    var isUsingDeviceCalendars: Bool { access == .granted }
    var defaultCalendarID: String? { backend.defaultCalendarID ?? calendars.first?.id }
    var editableCalendars: [CalendarInfo] { calendars.filter(\.isEditable) }

    func calendar(_ id: String) -> CalendarInfo? {
        calendars.first { $0.id == id }
    }

    func color(of event: CalendarEvent) -> Color {
        calendar(event.calendarID)?.color ?? .accentColor
    }

    /// Asks for full access once; afterwards only Settings can change the answer.
    func requestAccess() async {
        guard access == .notDetermined, let eventStore else { return }
        let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
        access = granted ? .granted : .denied
        if granted { backend = EventKitCalendarBackend(store: eventStore) }
        reload()
    }

    func reload() {
        calendars = backend.calendars
        cache = [:]
        revision += 1
    }

    /// Visible calendars only, sorted by start (all-day first on the same start).
    func events(in interval: DateInterval) -> [CalendarEvent] {
        _ = revision
        if let cached = cache[interval] { return cached }
        let events = backend.events(in: interval)
            .filter { !hiddenCalendarIDs.contains($0.calendarID) }
            .sorted { ($0.start, $0.isAllDay ? 0 : 1) < ($1.start, $1.isAllDay ? 0 : 1) }
        if cache.count > 32 { cache = [:] }
        cache[interval] = events
        return events
    }

    func upcoming(from date: Date = Date(), days: Int = 7, limit: Int = 6, calendar: Calendar = .current) -> [CalendarEvent] {
        let end = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
        return Array(events(in: DateInterval(start: date, end: max(end, date))).filter { $0.end > date }.prefix(limit))
    }

    @discardableResult
    func save(_ event: CalendarEvent) -> Bool {
        do {
            try backend.save(event)
            lastError = nil
            reload()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func delete(_ event: CalendarEvent) {
        do {
            try backend.delete(event)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    func toggleVisibility(_ id: String) {
        if hiddenCalendarIDs.contains(id) { hiddenCalendarIDs.remove(id) } else { hiddenCalendarIDs.insert(id) }
        cache = [:]
        revision += 1
    }

    /// A new event at the next whole hour of `day` (or of now, when `day` is today).
    func draft(on day: Date, calendar: Calendar = .current, now: Date = Date()) -> CalendarEvent {
        let base: Date
        if calendar.isDate(day, inSameDayAs: now) {
            base = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
        } else {
            base = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        }
        return CalendarEvent(title: "", start: base, end: base.addingTimeInterval(3600), calendarID: defaultCalendarID ?? "")
    }

    // MARK: Linux

    static let exportPath = "Calendar/linpad.ics"

    /// Writes `~/Calendar/linpad.ics` (last month to a year ahead) for Linux calendar apps.
    func exportICS(to host: any LinuxHost, now: Date = Date()) async -> String? {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let end = calendar.date(byAdding: .year, value: 1, to: now) ?? now
        let text = ICSWriter.document(events(in: DateInterval(start: start, end: end)), calendars: calendars, now: now)
        let path = (host.homeDirectory as NSString).appendingPathComponent(Self.exportPath)
        let directory = (path as NSString).deletingLastPathComponent
        let mkdir = await host.run("mkdir -p -- " + ShellQuote.quote(directory))
        guard mkdir.succeeded else { return mkdir.stderr.isEmpty ? "Couldn't create \(directory)" : mkdir.stderr }
        do {
            try await host.writeFile(path, data: Data(text.utf8))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func observeChanges() {
        changeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }
}

// MARK: - iCalendar

/// RFC 5545 output: CRLF line ends, escaped text, lines folded at 75 octets.
enum ICSWriter {
    static func document(_ events: [CalendarEvent], calendars: [CalendarInfo], now: Date) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//LinPad//Calendar//EN", "CALSCALE:GREGORIAN",
                     "X-WR-CALNAME:LinPad"]
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(event.id)@linpad")
            lines.append("DTSTAMP:\(utc(now))")
            if event.isAllDay {
                lines.append("DTSTART;VALUE=DATE:\(dateOnly(event.start))")
                let end = event.end > event.start ? event.end : event.start.addingTimeInterval(86_400)
                lines.append("DTEND;VALUE=DATE:\(dateOnly(end))")
            } else {
                lines.append("DTSTART:\(utc(event.start))")
                lines.append("DTEND:\(utc(max(event.end, event.start)))")
            }
            lines.append("SUMMARY:\(escape(event.title))")
            if !event.location.isEmpty { lines.append("LOCATION:\(escape(event.location))") }
            if !event.notes.isEmpty { lines.append("DESCRIPTION:\(escape(event.notes))") }
            if let name = calendars.first(where: { $0.id == event.calendarID })?.title {
                lines.append("CATEGORIES:\(escape(name))")
            }
            if let minutes = event.alertMinutes {
                lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:\(escape(event.title))",
                          "TRIGGER:-PT\(minutes)M", "END:VALARM"]
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Continuation lines start with a space; a fold never splits a UTF-8 sequence.
    static func fold(_ line: String) -> String {
        var result = ""
        var count = 0
        for character in line {
            let size = String(character).utf8.count
            if count + size > 75 {
                result += "\r\n "
                count = 1
            }
            result.append(character)
            count += size
        }
        return result
    }

    private static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// All-day dates are floating: the user's calendar day, not a UTC instant.
    private static func dateOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}
