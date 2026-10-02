import SwiftUI
import UIKit

/// The iPad's calendars (EventKit) in a desktop window: month, week and day views, event
/// editing, and an .ics export for Linux calendar apps.
enum CalendarApp {
    static let id = "calendar"
    /// Launch argument: the day to show, `yyyy-MM-dd`.
    static let dateArgument = "date"
    /// Posted with `dateArgument: Date` when the app is asked to show a day while it is open.
    static let showDateRequested = Notification.Name("CalendarApp.showDateRequested")

    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: id, name: "Calendar", symbol: "calendar", category: .accessories,
            defaultSize: CGSize(width: 980, height: 660), allowsMultipleWindows: false, showsOnDesktop: false
        ) { context in
            AnyView(CalendarAppView(context: context))
        }
    }

    static func argument(for date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    static func date(fromArgument text: String?) -> Date? {
        guard let text else { return nil }
        return try? Date.ISO8601FormatStyle().year().month().day().parse(text)
    }
}

enum CalendarViewMode: String, CaseIterable, Identifiable {
    case month, week, day

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var unit: Calendar.Component {
        switch self {
        case .month: .month
        case .week: .weekOfYear
        case .day: .day
        }
    }
}

/// Calendar keys: T today, N new event, arrows move the selected day, ⌘arrows the period,
/// ⌘1–3 the view, Escape closes the editor.
enum CalendarKey: String, CaseIterable {
    case today, new, left, right, up, down, previousPeriod, nextPeriod, month, week, day, open, escape

    var command: UIKeyCommand {
        let (input, flags): (String, UIKeyModifierFlags) = {
            switch self {
            case .today: ("t", [])
            case .new: ("n", [])
            case .left: (UIKeyCommand.inputLeftArrow, [])
            case .right: (UIKeyCommand.inputRightArrow, [])
            case .up: (UIKeyCommand.inputUpArrow, [])
            case .down: (UIKeyCommand.inputDownArrow, [])
            case .previousPeriod: (UIKeyCommand.inputLeftArrow, .command)
            case .nextPeriod: (UIKeyCommand.inputRightArrow, .command)
            case .month: ("1", .command)
            case .week: ("2", .command)
            case .day: ("3", .command)
            case .open: ("\r", [])
            case .escape: (UIKeyCommand.inputEscape, [])
            }
        }()
        let command = UIKeyCommand(title: "", action: #selector(CalendarKeyView.perform(_:)), input: input,
                                   modifierFlags: flags, propertyList: rawValue)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    static let commands = allCases.map(\.command)
}

final class CalendarKeyView: UIView {
    var onKey: ((CalendarKey) -> Void)?

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? { CalendarKey.commands }

    @objc func perform(_ sender: UIKeyCommand) {
        guard let raw = sender.propertyList as? String, let key = CalendarKey(rawValue: raw) else { return }
        onKey?(key)
    }
}

private struct CalendarKeyHost: UIViewRepresentable {
    let isActive: Bool
    let onKey: (CalendarKey) -> Void

    func makeUIView(context: Context) -> CalendarKeyView {
        let view = CalendarKeyView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: CalendarKeyView, context: Context) {
        view.onKey = onKey
        if isActive, !view.isFirstResponder {
            DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
        } else if !isActive, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

struct CalendarAppView: View {
    let context: AppLaunchContext
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopController) private var controller
    @Environment(\.desktopWindowIsFocused) private var isWindowFocused
    @Environment(\.calendar) private var calendar
    @AppStorage(CalendarSettings.weekNumbersKey) private var showsWeekNumbers = false
    @AppStorage("calendar.viewMode") private var modeID = CalendarViewMode.month.rawValue
    @AppStorage("calendar.showsSidebar") private var showsSidebar = true
    @State private var selection: Date
    @State private var sidebarMonth: Date
    @State private var editing: CalendarEvent?
    @State private var exportMessage: String?

    init(context: AppLaunchContext) {
        self.context = context
        let day = CalendarApp.date(fromArgument: context.arguments[CalendarApp.dateArgument]) ?? Date()
        _selection = State(initialValue: day)
        _sidebarMonth = State(initialValue: CalendarMath.startOfMonth(day, calendar: .current))
    }

    private var mode: CalendarViewMode { CalendarViewMode(rawValue: modeID) ?? .month }

    var body: some View {
        Group {
            if let store = controller?.calendarStore {
                content(store)
            } else {
                AppEmptyState(symbol: "calendar", title: "Calendar needs the desktop.")
            }
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear { context.window.setTitle("Calendar") }
        .onReceive(NotificationCenter.default.publisher(for: CalendarApp.showDateRequested)) { note in
            if let day = note.userInfo?[CalendarApp.dateArgument] as? Date { select(day) }
        }
    }

    private func content(_ store: CalendarStore) -> some View {
        VStack(spacing: 0) {
            toolbar(store)
            if store.access == .denied {
                InlineBanner(kind: .info, message: "Calendar access is off, so events are kept in LinPad on this iPad only.",
                             actionTitle: "Open Settings", action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                })
            } else if store.access == .notDetermined {
                InlineBanner(kind: .info, message: "Show the calendars from this iPad's accounts (iCloud, Google, Exchange).",
                             actionTitle: "Allow Access", action: {
                    Task { await store.requestAccess() }
                })
            }
            if let error = store.lastError {
                InlineBanner(kind: .error, message: error)
            }
            HStack(spacing: 0) {
                if showsSidebar {
                    sidebar(store)
                    ThemedSeparator(vertical: true)
                }
                Group {
                    switch mode {
                    case .month:
                        MonthGridView(store: store, month: selection, selection: selection, showsWeekNumbers: showsWeekNumbers,
                                      onSelect: select, onCreate: { day in editing = store.draft(on: day, calendar: calendar) },
                                      onEdit: { editing = $0 })
                    case .week:
                        TimeGridView(store: store, days: CalendarMath.weekDays(containing: selection, calendar: calendar),
                                     selection: selection, onSelect: select, onCreate: create(at:), onEdit: { editing = $0 })
                    case .day:
                        TimeGridView(store: store, days: [calendar.startOfDay(for: selection)], selection: selection,
                                     onSelect: select, onCreate: create(at:), onEdit: { editing = $0 })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if let event = editing {
                ZStack {
                    theme.scrim.opacity(0.6).contentShape(Rectangle()).onTapGesture { editing = nil }
                    EventEditorView(store: store, event: event, onDone: { editing = nil })
                }
                .transition(.opacity)
            }
        }
        .animation(DesktopMotion.quick, value: editing?.id)
        .background {
            CalendarKeyHost(isActive: isWindowFocused && editing == nil) { handle($0, store: store) }
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .accessibilityIdentifier("calendar.app")
    }

    private func toolbar(_ store: CalendarStore) -> some View {
        AppToolbar {
            ToolbarIconButton("sidebar.left", help: "Sidebar", isActive: showsSidebar) { showsSidebar.toggle() }
            ToolbarTextButton(title: "Today") { select(Date()) }
                .accessibilityIdentifier("calendar.today")
            ToolbarIconButton("chevron.left", help: "Previous") { step(-1) }
            ToolbarIconButton("chevron.right", help: "Next") { step(1) }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .padding(.leading, 6)
                .accessibilityIdentifier("calendar.title")
            Spacer(minLength: 8)
            Picker("View", selection: $modeID) {
                ForEach(CalendarViewMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("calendar.mode")
            ToolbarIconButton("plus", help: "New Event") { editing = store.draft(on: selection, calendar: calendar) }
                .accessibilityIdentifier("calendar.new")
        }
    }

    private var title: String {
        switch mode {
        case .month:
            return selection.formatted(.dateTime.month(.wide).year())
        case .week:
            let days = CalendarMath.weekDays(containing: selection, calendar: calendar)
            let week = showsWeekNumbers ? " · Week \(CalendarMath.weekNumber(of: selection, calendar: calendar))" : ""
            return "\(days[0].formatted(.dateTime.day().month(.abbreviated))) – \(days[6].formatted(.dateTime.day().month(.abbreviated).year()))\(week)"
        case .day:
            return selection.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        }
    }

    private func sidebar(_ store: CalendarStore) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MiniMonthView(store: store, month: $sidebarMonth, selection: selection,
                              showsWeekNumbers: showsWeekNumbers, onSelect: select)
                let groups = Dictionary(grouping: store.calendars, by: \.account)
                ForEach(groups.keys.sorted(), id: \.self) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.isEmpty ? "Calendars" : account)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                        ForEach(groups[account] ?? []) { info in
                            calendarRow(info, store: store)
                        }
                    }
                }
                Toggle("Week Numbers", isOn: $showsWeekNumbers)
                    .font(.system(size: 12))
                    .tint(theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    ToolbarTextButton(title: "Export for Linux", symbol: "square.and.arrow.up") {
                        Task { await export(store) }
                    }
                    .accessibilityIdentifier("calendar.export")
                    Text(exportMessage ?? "Writes ~/\(CalendarStore.exportPath) for Thunderbird and other Linux apps.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
        }
        .frame(width: showsWeekNumbers ? 262 : 236)
        .background(theme.titleBarInactive.opacity(0.5))
    }

    private func calendarRow(_ info: CalendarInfo, store: CalendarStore) -> some View {
        let visible = !store.hiddenCalendarIDs.contains(info.id)
        return Button { store.toggleVisibility(info.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: visible ? "checkmark.square.fill" : "square")
                    .foregroundStyle(info.color)
                Text(info.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(visible ? .isSelected : [])
    }

    // MARK: Actions

    private func select(_ day: Date) {
        selection = day
        if !calendar.isDate(day, equalTo: sidebarMonth, toGranularity: .month) {
            sidebarMonth = CalendarMath.startOfMonth(day, calendar: calendar)
        }
    }

    private func step(_ count: Int) {
        select(CalendarMath.step(selection, by: count, unit: mode.unit, calendar: calendar))
    }

    private func create(at start: Date) {
        guard let store = controller?.calendarStore else { return }
        var event = store.draft(on: start, calendar: calendar)
        event.start = start
        event.end = start.addingTimeInterval(3600)
        editing = event
    }

    private func handle(_ key: CalendarKey, store: CalendarStore) {
        switch key {
        case .today: select(Date())
        case .new: editing = store.draft(on: selection, calendar: calendar)
        case .left: select(CalendarMath.step(selection, by: -1, unit: .day, calendar: calendar))
        case .right: select(CalendarMath.step(selection, by: 1, unit: .day, calendar: calendar))
        case .up: select(CalendarMath.step(selection, by: -7, unit: .day, calendar: calendar))
        case .down: select(CalendarMath.step(selection, by: 7, unit: .day, calendar: calendar))
        case .previousPeriod: step(-1)
        case .nextPeriod: step(1)
        case .month: modeID = CalendarViewMode.month.rawValue
        case .week: modeID = CalendarViewMode.week.rawValue
        case .day: modeID = CalendarViewMode.day.rawValue
        case .open:
            if let first = store.events(in: CalendarMath.day(selection, calendar: calendar)).first { editing = first }
        case .escape: editing = nil
        }
    }

    private func export(_ store: CalendarStore) async {
        if let error = await store.exportICS(to: context.host) {
            exportMessage = "Export failed: \(error)"
        } else {
            exportMessage = "Saved ~/\(CalendarStore.exportPath) at \(Date().formatted(date: .omitted, time: .shortened))."
            context.desktop.notify("Calendar exported to ~/\(CalendarStore.exportPath)")
        }
    }
}
