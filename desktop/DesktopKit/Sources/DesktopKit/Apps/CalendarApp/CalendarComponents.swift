import SwiftUI

enum CalendarSettings {
    static let weekNumbersKey = "calendar.showWeekNumbers"
}

/// A month of day numbers: today filled with the accent, the selected day ringed, a dot under
/// days with events. Used by the panel popover, the Calendar app's sidebar and the widget.
struct MiniMonthView: View {
    let store: CalendarStore
    @Binding var month: Date
    var selection: Date?
    var showsWeekNumbers = false
    var showsNavigation = true
    var compact = false
    var onSelect: ((Date) -> Void)?

    @Environment(\.desktopTheme) private var theme
    @Environment(\.calendar) private var calendar

    private var cell: CGFloat { compact ? 22 : 30 }

    var body: some View {
        let days = CalendarMath.monthGrid(for: month, calendar: calendar)
        let grid = CalendarMath.gridInterval(for: month, calendar: calendar)
        let busy = Set(store.events(in: grid).flatMap { busyDays(of: $0) })
        return VStack(spacing: compact ? 2 : 4) {
            header
            HStack(spacing: 0) {
                if showsWeekNumbers { Text("").frame(width: cell) }
                ForEach(Array(CalendarMath.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).frame(width: cell)
                }
            }
            .font(.system(size: compact ? 9 : 11, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    if showsWeekNumbers {
                        Text("\(CalendarMath.weekNumber(of: days[week * 7], calendar: calendar))")
                            .font(.system(size: compact ? 8 : 10).monospacedDigit())
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                            .frame(width: cell)
                    }
                    ForEach(days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                        dayCell(day, hasEvents: busy.contains(calendar.startOfDay(for: day)))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var header: some View {
        HStack {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
            Spacer()
            if showsNavigation {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 24) }
                    .accessibilityLabel("Previous Month")
                Button { month = CalendarMath.startOfMonth(Date(), calendar: calendar) } label: {
                    Image(systemName: "circle.fill").font(.system(size: 6)).frame(width: 20, height: 24)
                }
                .accessibilityLabel("This Month")
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 24) }
                    .accessibilityLabel("Next Month")
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .padding(.horizontal, 2)
    }

    private func dayCell(_ day: Date, hasEvents: Bool) -> some View {
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isSelected = selection.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        return Button { onSelect?(day) } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: compact ? 10 : 12, weight: isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isToday ? theme.accent.readableLabel
                                     : inMonth ? theme.primaryText : theme.secondaryText.opacity(0.6))
                    .frame(width: cell - 6, height: cell - 6)
                    .background(Circle().fill(isToday ? theme.accent : Color.clear))
                    .overlay(Circle().strokeBorder(isSelected && !isToday ? theme.accent : Color.clear, lineWidth: 1.5))
                Circle().fill(hasEvents ? (isToday ? theme.primaryText : theme.accent) : Color.clear)
                    .frame(width: 3, height: 3)
            }
            .frame(width: cell, height: cell + (compact ? 0 : 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onSelect == nil)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(isToday ? .isSelected : [])
    }

    private func busyDays(of event: CalendarEvent) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: event.start)
        let last = event.end > event.start ? event.end.addingTimeInterval(-1) : event.start
        while day <= last, days.count < 42 {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    private func shift(_ months: Int) {
        month = CalendarMath.step(month, by: months, unit: .month, calendar: calendar)
    }
}

/// The next events, grouped under Today / Tomorrow / weekday headings.
struct UpcomingEventsList: View {
    let store: CalendarStore
    var limit = 6
    var days = 7
    var compact = false
    var onSelect: ((CalendarEvent) -> Void)?

    @Environment(\.desktopTheme) private var theme
    @Environment(\.calendar) private var calendar

    var body: some View {
        TimelineView(.everyMinute) { context in
            let events = store.upcoming(from: Self.minute(context.date), days: days, limit: limit, calendar: calendar)
            VStack(alignment: .leading, spacing: compact ? 4 : 6) {
                if events.isEmpty {
                    Text("No upcoming events")
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index == 0 || !calendar.isDate(events[index - 1].start, inSameDayAs: event.start) {
                        Text(Self.dayTitle(event.start, now: context.date, calendar: calendar))
                            .font(.system(size: compact ? 10 : 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.top, index == 0 ? 0 : 2)
                    }
                    row(event)
                }
            }
        }
        .accessibilityIdentifier("calendar.upcoming")
    }

    private func row(_ event: CalendarEvent) -> some View {
        Button { onSelect?(event) } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(store.color(of: event)).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title.isEmpty ? "New Event" : event.title)
                        .font(.system(size: compact ? 11 : 12, weight: .medium))
                        .lineLimit(1)
                    Text(Self.timeText(event))
                        .font(.system(size: compact ? 10 : 11).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: compact ? 26 : 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onSelect == nil)
        .foregroundStyle(theme.primaryText)
    }

    static func timeText(_ event: CalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return event.location.isEmpty ? "\(start) – \(end)" : "\(start) – \(end) · \(event.location)"
    }

    static func dayTitle(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// Fetches keyed by the minute, so a redraw within the same minute hits the store's cache.
    private static func minute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }
}

/// What the panel clock opens: the date, a month, and what is coming up.
struct CalendarPopover: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @Environment(\.calendar) private var calendar
    @AppStorage(CalendarSettings.weekNumbersKey) private var showsWeekNumbers = false
    @State private var month = CalendarMath.startOfMonth(Date(), calendar: .current)
    @Environment(\.dismiss) private var dismiss

    private var store: CalendarStore { controller.calendarStore }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date.formatted(.dateTime.weekday(.wide)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    Text(context.date.formatted(.dateTime.day().month(.wide).year()))
                        .font(.title3.weight(.semibold))
                }
            }
            MiniMonthView(store: store, month: $month, selection: nil, showsWeekNumbers: showsWeekNumbers) { day in
                openCalendar(on: day)
            }
            Divider().overlay(theme.separator)
            UpcomingEventsList(store: store, limit: 5) { event in openCalendar(on: event.start) }
            if store.access == .notDetermined {
                Button("Show iPad Calendars…", systemImage: "calendar.badge.plus") {
                    Task { await store.requestAccess() }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
            }
            HStack {
                Toggle("Week Numbers", isOn: $showsWeekNumbers)
                    .toggleStyle(.button)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .fixedSize()
                    .tint(theme.accent)
                Spacer()
                Button("Open Calendar") { openCalendar(on: Date()) }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityIdentifier("calendar.popover.open")
            }
        }
        .foregroundStyle(theme.primaryText)
        .padding(16)
        .frame(width: showsWeekNumbers ? 280 : 256)
        .background(theme.panelBackground.opacity(0.4))
        .presentationCompactAdaptation(.popover)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.popover")
    }

    private func openCalendar(on day: Date) {
        dismiss()
        controller.open(appID: CalendarApp.id, arguments: [CalendarApp.dateArgument: CalendarApp.argument(for: day)])
        NotificationCenter.default.post(name: CalendarApp.showDateRequested, object: nil,
                                        userInfo: [CalendarApp.dateArgument: day])
    }
}

/// The panel clock's popover, pointing away from the screen edge the style's panel sits on.
private struct CalendarPopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let controller: DesktopController?
    @Environment(\.desktopStyle) private var style

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, arrowEdge: style.quickSettingsAlignment == .bottomTrailing ? .bottom : .top) {
            if let controller {
                CalendarPopover(controller: controller)
            }
        }
    }
}

extension View {
    func calendarPopover(isPresented: Binding<Bool>, controller: DesktopController?) -> some View {
        modifier(CalendarPopoverModifier(isPresented: isPresented, controller: controller))
    }
}
