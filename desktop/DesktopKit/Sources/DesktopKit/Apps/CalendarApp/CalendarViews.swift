import SwiftUI

// MARK: - Month

struct MonthGridView: View {
    let store: CalendarStore
    let month: Date
    let selection: Date
    let showsWeekNumbers: Bool
    let onSelect: (Date) -> Void
    let onCreate: (Date) -> Void
    let onEdit: (CalendarEvent) -> Void

    @Environment(\.desktopTheme) private var theme
    @Environment(\.calendar) private var calendar

    private let weekNumberWidth: CGFloat = 30

    var body: some View {
        let days = CalendarMath.monthGrid(for: month, calendar: calendar)
        let events = store.events(in: CalendarMath.gridInterval(for: month, calendar: calendar))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsWeekNumbers { Color.clear.frame(width: weekNumberWidth) }
                ForEach(Array(CalendarMath.shortWeekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 8)
                }
            }
            .frame(height: 26)
            ThemedSeparator()
            GeometryReader { proxy in
                let rowHeight = proxy.size.height / 6
                let visibleChips = max(Int((rowHeight - 28) / 19), 0)
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { week in
                        HStack(spacing: 0) {
                            if showsWeekNumbers {
                                Text("\(CalendarMath.weekNumber(of: days[week * 7], calendar: calendar))")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(theme.secondaryText)
                                    .frame(width: weekNumberWidth, height: rowHeight, alignment: .top)
                                    .padding(.top, 8)
                            }
                            ForEach(days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                                let dayEvents = events.filter { $0.overlaps(CalendarMath.day(day, calendar: calendar)) }
                                dayCell(day, events: dayEvents, chips: visibleChips)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .overlay(alignment: .trailing) { ThemedSeparator(vertical: true) }
                            }
                        }
                        .frame(height: rowHeight)
                        .overlay(alignment: .bottom) { ThemedSeparator() }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.month")
    }

    private func dayCell(_ day: Date, events: [CalendarEvent], chips: Int) -> some View {
        let isToday = calendar.isDateInToday(day)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? theme.accent.readableLabel : inMonth ? theme.primaryText : theme.secondaryText.opacity(0.6))
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(isToday ? theme.accent : Color.clear))
            }
            ForEach(events.prefix(chips)) { event in
                Button { onEdit(event) } label: { chip(event) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("calendar.event")
            }
            if events.count > chips {
                Text("\(events.count - chips) more")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(isSelected ? theme.accent.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onCreate(day) }
        .onTapGesture { onSelect(day) }
        .contextMenu {
            Button("New Event", systemImage: "plus") { onCreate(day) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private func chip(_ event: CalendarEvent) -> some View {
        let color = store.color(of: event)
        let title = Text(event.title.isEmpty ? "New Event" : event.title)
        return HStack(spacing: 4) {
            if event.isAllDay {
                title.foregroundStyle(color.readableLabel)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
                // The time goes first when the column is too narrow for both.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        title.fixedSize()
                        Spacer(minLength: 2)
                        Text(event.start.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize()
                    }
                    title
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 4)
        .frame(height: 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(event.isAllDay ? color : Color.clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Week and day

struct TimeGridView: View {
    let store: CalendarStore
    let days: [Date]
    let selection: Date
    let onSelect: (Date) -> Void
    let onCreate: (Date) -> Void
    let onEdit: (CalendarEvent) -> Void

    @Environment(\.desktopTheme) private var theme
    @Environment(\.calendar) private var calendar

    private let hourHeight: CGFloat = 48
    private let gutter: CGFloat = 52

    var body: some View {
        let span = DateInterval(start: days.first ?? Date(),
                                end: CalendarMath.day(days.last ?? Date(), calendar: calendar).end)
        let events = store.events(in: span)
        VStack(spacing: 0) {
            header(events: events.filter(\.isAllDay))
            ThemedSeparator()
            ScrollViewReader { reader in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels
                        ForEach(days, id: \.self) { day in
                            dayColumn(day, events: events.filter { !$0.isAllDay && $0.overlaps(CalendarMath.day(day, calendar: calendar)) })
                                .overlay(alignment: .leading) { ThemedSeparator(vertical: true) }
                        }
                    }
                    .frame(height: hourHeight * 24)
                }
                .onAppear { reader.scrollTo(7, anchor: .top) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(days.count == 1 ? "calendar.day" : "calendar.week")
    }

    private func header(events: [CalendarEvent]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("all-day")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
                .frame(width: gutter, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 34)
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDateInToday(day)
                VStack(spacing: 4) {
                    Button { onSelect(day) } label: {
                        HStack(spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                .foregroundStyle(theme.secondaryText)
                            Text("\(calendar.component(.day, from: day))")
                                .fontWeight(.semibold)
                                .foregroundStyle(isToday ? theme.accent.readableLabel : theme.primaryText)
                                .frame(minWidth: 24, minHeight: 24)
                                .background(Circle().fill(isToday ? theme.accent : Color.clear))
                        }
                        .font(.system(size: 13).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(events.filter { $0.overlaps(CalendarMath.day(day, calendar: calendar)) }) { event in
                        Button { onEdit(event) } label: {
                            Text(event.title.isEmpty ? "New Event" : event.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(store.color(of: event).readableLabel)
                                .padding(.horizontal, 6)
                                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 4).fill(store.color(of: event)))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(calendar.isDate(day, inSameDayAs: selection) && days.count > 1
                            ? theme.accent.opacity(0.08) : Color.clear)
            }
        }
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : Self.hourText(hour, calendar: calendar))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: gutter, height: hourHeight, alignment: .topTrailing)
                    .padding(.trailing, 6)
                    .offset(y: -6)
                    .id(hour)
            }
        }
    }

    private func dayColumn(_ day: Date, events: [CalendarEvent]) -> some View {
        let placements = EventColumns.layout(events)
        let dayRange = CalendarMath.day(day, calendar: calendar)
        return GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle().fill(Color.clear)
                            .frame(height: hourHeight)
                            .overlay(alignment: .top) { ThemedSeparator() }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2, coordinateSpace: .local) { location in
                    onCreate(slot(at: location.y, on: day))
                }
                .onTapGesture { onSelect(day) }
                ForEach(events) { event in
                    let placement = placements[event.id] ?? .init(column: 0, columnCount: 1)
                    let top = event.start <= dayRange.start ? 0 : CalendarMath.hourOffset(of: event.start, calendar: calendar)
                    let bottom = event.end >= dayRange.end ? 24 : CalendarMath.hourOffset(of: event.end, calendar: calendar)
                    let width = proxy.size.width / CGFloat(placement.columnCount)
                    eventBlock(event)
                        .frame(width: max(width - 3, 10), height: max(CGFloat(bottom - top) * hourHeight - 2, 18))
                        .offset(x: CGFloat(placement.column) * width + 1, y: CGFloat(top) * hourHeight + 1)
                }
                if calendar.isDateInToday(day) {
                    TimelineView(.everyMinute) { context in
                        let y = CalendarMath.hourOffset(of: context.date, calendar: calendar) * hourHeight
                        HStack(spacing: 0) {
                            Circle().fill(theme.urgent).frame(width: 8, height: 8)
                            Rectangle().fill(theme.urgent).frame(height: 1.5)
                        }
                        .offset(x: -4, y: y - 4)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func eventBlock(_ event: CalendarEvent) -> some View {
        let color = store.color(of: event)
        return Button { onEdit(event) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title.isEmpty ? "New Event" : event.title)
                    .font(.system(size: 11, weight: .semibold))
                Text(UpcomingEventsList.timeText(event))
                    .font(.system(size: 10))
                    .opacity(0.85)
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.28)))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar.event")
    }

    /// The half hour under `y`.
    private func slot(at y: CGFloat, on day: Date) -> Date {
        let halfHours = Int(max(0, min(47, y / (hourHeight / 2))))
        return calendar.date(bySettingHour: halfHours / 2, minute: (halfHours % 2) * 30, second: 0, of: day) ?? day
    }

    private static func hourText(_ hour: Int, calendar: Calendar) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

// MARK: - Editor

struct EventEditorView: View {
    let store: CalendarStore
    let onDone: () -> Void
    @State private var event: CalendarEvent
    @State private var confirmsDeletion = false
    @FocusState private var titleFocused: Bool
    @Environment(\.desktopTheme) private var theme

    private let isNew: Bool

    static let alertChoices: [(String, Int?)] = [
        ("None", nil), ("At time of event", 0), ("5 minutes before", 5), ("15 minutes before", 15),
        ("30 minutes before", 30), ("1 hour before", 60), ("1 day before", 1440),
    ]

    init(store: CalendarStore, event: CalendarEvent, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        _event = State(initialValue: event)
        isNew = store.events(in: DateInterval(start: event.start.addingTimeInterval(-1), end: event.end.addingTimeInterval(1)))
            .allSatisfy { $0.id != event.id }
    }

    private var isEditable: Bool { store.calendar(event.calendarID)?.isEditable ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isNew ? "New Event" : "Edit Event").font(.headline)
                if event.isRecurring {
                    Label("Repeats", systemImage: "repeat").font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer()
            }
            TextField("Title", text: $event.title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .accessibilityIdentifier("calendar.editor.title")
            TextField("Location", text: $event.location)
                .textFieldStyle(.roundedBorder)
            Toggle("All-day", isOn: $event.isAllDay)
                .tint(theme.accent)
            DatePicker("Starts", selection: startKeepingDuration, displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
            DatePicker("Ends", selection: $event.end, in: event.start..., displayedComponents: event.isAllDay ? [.date] : [.date, .hourAndMinute])
            HStack {
                Text("Calendar")
                Spacer()
                Picker("Calendar", selection: $event.calendarID) {
                    ForEach(store.editableCalendars) { info in
                        Label(info.title, systemImage: "circle.fill").tag(info.id)
                    }
                }
                .labelsHidden()
                .tint(store.calendar(event.calendarID)?.color ?? theme.accent)
            }
            HStack {
                Text("Alert")
                Spacer()
                Picker("Alert", selection: $event.alertMinutes) {
                    ForEach(Self.alertChoices, id: \.0) { Text($0.0).tag($0.1) }
                }
                .labelsHidden()
            }
            TextField("Notes", text: $event.notes, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            HStack {
                if !isNew && isEditable {
                    Button("Delete", role: .destructive) { confirmsDeletion = true }
                        .accessibilityIdentifier("calendar.editor.delete")
                }
                Spacer()
                Button("Cancel", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isEditable)
                    .accessibilityIdentifier("calendar.editor.save")
            }
        }
        .font(.system(size: 13))
        .padding(18)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).fill(theme.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadius + 2, style: .continuous).strokeBorder(theme.separator))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 6)
        .onAppear { if isNew { titleFocused = true } }
        .onChange(of: event.isAllDay) { _, allDay in
            guard allDay else { return }
            let calendar = Calendar.current
            event.start = calendar.startOfDay(for: event.start)
            event.end = CalendarMath.day(event.start, calendar: calendar).end
        }
        .confirmationDialog("Delete “\(event.title)”?", isPresented: $confirmsDeletion) {
            Button(event.isRecurring ? "Delete This Event Only" : "Delete Event", role: .destructive) {
                store.delete(event)
                onDone()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar.editor")
    }

    /// Moving the start keeps the duration, as Calendar does.
    private var startKeepingDuration: Binding<Date> {
        Binding(get: { event.start }, set: { start in
            let duration = max(event.end.timeIntervalSince(event.start), 0)
            event.start = start
            event.end = start.addingTimeInterval(duration)
        })
    }

    private func save() {
        if event.title.trimmingCharacters(in: .whitespaces).isEmpty { event.title = "New Event" }
        if store.save(event) { onDone() }
    }
}
