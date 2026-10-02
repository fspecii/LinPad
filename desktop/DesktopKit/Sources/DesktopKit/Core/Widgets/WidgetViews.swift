import SwiftUI

private struct WidgetsAreLiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the desktop is locked or the app is in the background, so widgets stop
    /// polling and timers.
    var widgetsAreLive: Bool {
        get { self[WidgetsAreLiveKey.self] }
        set { self[WidgetsAreLiveKey.self] = newValue }
    }
}

/// The content of one widget; the frame and edit chrome come from the widget layer.
struct DesktopWidgetContent: View {
    let widget: DesktopWidget
    let controller: DesktopController
    let setOption: (String, String?) -> Void

    var body: some View {
        switch widget.kind {
        case .clock: ClockWidget(isAnalog: widget.options["style"] != "digital")
        case .calendar: CalendarWidget(store: controller.calendarStore, controller: controller)
        case .weather: WeatherWidget(model: controller.widgets.weather)
        case .systemMonitor: SystemMonitorWidget(controller: controller)
        case .nowPlaying: NowPlayingWidget(center: controller.nowPlaying)
        case .notes: NotesWidget(text: widget.options["text"] ?? "", onChange: { setOption("text", $0) })
        case .battery: BatteryWidget(status: controller.systemStatus)
        case .network: NetworkWidget(status: controller.systemStatus)
        case .upcomingEvents: UpcomingEventsWidget(store: controller.calendarStore, controller: controller)
        }
    }
}

// MARK: - Clock

struct ClockWidget: View {
    let isAnalog: Bool
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        TimelineView(.everyMinute) { context in
            if isAnalog {
                AnalogClockFace(date: context.date)
                    .padding(4)
            } else {
                VStack(spacing: 4) {
                    Text(context.date.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Date().formatted(date: .omitted, time: .shortened))
    }
}

/// Hours and minutes only: the face changes once a minute, so it costs nothing in between.
struct AnalogClockFace: View {
    let date: Date
    @Environment(\.desktopTheme) private var theme
    @Environment(\.calendar) private var calendar

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side / 2
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: side, height: side)),
                         with: .color(theme.primaryText.opacity(0.06)))
            for tick in 0..<60 {
                let isHour = tick % 5 == 0
                let angle = Angle.degrees(Double(tick) * 6 - 90)
                let outer = radius - 4
                let inner = outer - (isHour ? radius * 0.12 : radius * 0.05)
                var path = Path()
                path.move(to: point(center, inner, angle))
                path.addLine(to: point(center, outer, angle))
                context.stroke(path, with: .color(isHour ? theme.primaryText : theme.secondaryText.opacity(0.5)),
                               lineWidth: isHour ? 2 : 1)
            }
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minute = Double(parts.minute ?? 0)
            let hour = Double((parts.hour ?? 0) % 12) + minute / 60
            hand(context, center, length: radius * 0.5, angle: .degrees(hour * 30 - 90), width: 4.5, color: theme.primaryText)
            hand(context, center, length: radius * 0.78, angle: .degrees(minute * 6 - 90), width: 3, color: theme.primaryText)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)), with: .color(theme.accent))
        }
    }

    private func point(_ center: CGPoint, _ distance: CGFloat, _ angle: Angle) -> CGPoint {
        CGPoint(x: center.x + cos(angle.radians) * distance, y: center.y + sin(angle.radians) * distance)
    }

    private func hand(_ context: GraphicsContext, _ center: CGPoint, length: CGFloat, angle: Angle, width: CGFloat, color: Color) {
        var path = Path()
        path.move(to: center)
        path.addLine(to: point(center, length, angle))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

// MARK: - Calendar

struct CalendarWidget: View {
    let store: CalendarStore
    let controller: DesktopController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.everyMinute) { context in
                MiniMonthView(store: store, month: .constant(CalendarMath.startOfMonth(context.date, calendar: .current)),
                              selection: nil, showsNavigation: false, compact: true) { day in
                    controller.open(appID: CalendarApp.id, arguments: [CalendarApp.dateArgument: CalendarApp.argument(for: day)])
                    NotificationCenter.default.post(name: CalendarApp.showDateRequested, object: nil,
                                                    userInfo: [CalendarApp.dateArgument: day])
                }
            }
            .frame(maxWidth: .infinity)
            UpcomingEventsList(store: store, limit: 2, days: 14, compact: true)
            Spacer(minLength: 0)
        }
    }
}

struct UpcomingEventsWidget: View {
    let store: CalendarStore
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "Up Next", symbol: "calendar")
            ScrollView {
                UpcomingEventsList(store: store, limit: 12, days: 14, compact: true) { event in
                    controller.open(appID: CalendarApp.id, arguments: [CalendarApp.dateArgument: CalendarApp.argument(for: event.start)])
                    NotificationCenter.default.post(name: CalendarApp.showDateRequested, object: nil,
                                                    userInfo: [CalendarApp.dateArgument: event.start])
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Weather

struct WeatherWidget: View {
    let model: WeatherModel
    @Environment(\.desktopTheme) private var theme
    @Environment(\.widgetsAreLive) private var isLive
    @State private var cityDraft = ""

    var body: some View {
        Group {
            if let report = model.report {
                reportView(report)
            } else if model.needsCity || model.error != nil {
                VStack(alignment: .leading, spacing: 8) {
                    WidgetHeader(title: "Weather", symbol: "cloud.sun")
                    Text(model.error ?? "Type a city to see its weather.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                    cityField
                    Spacer(minLength: 0)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: isLive) {
            guard isLive else { return }
            while !Task.isCancelled {
                await model.refreshIfStale()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .contextMenu {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            if !model.city.isEmpty {
                Button("Use Current Location", systemImage: "location") {
                    model.city = ""
                    Task { await model.refresh() }
                }
            }
        }
    }

    private var cityField: some View {
        TextField("City", text: $cityDraft)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .submitLabel(.search)
            .onSubmit {
                model.city = cityDraft
                Task { await model.refresh() }
            }
            .accessibilityIdentifier("widget.weather.city")
    }

    private func reportView(_ report: WeatherReport) -> some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(report.place).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(Int(report.temperature.rounded()))°")
                            .font(.system(size: 40, weight: .light, design: .rounded))
                    }
                    Spacer()
                    Image(systemName: report.condition.symbol(isDay: report.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 26))
                }
                Text(report.condition.title + (report.days.first.map { " · H \(Int($0.high.rounded()))° L \(Int($0.low.rounded()))°" } ?? ""))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                if proxy.size.height > 150 {
                    Spacer(minLength: 0)
                    HStack {
                        ForEach(report.days.dropFirst().prefix(3), id: \.date) { day in
                            VStack(spacing: 3) {
                                Text(Self.weekday(day.date)).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.secondaryText)
                                Image(systemName: WeatherCondition(code: day.code).symbol())
                                    .symbolRenderingMode(.multicolor)
                                    .font(.system(size: 14))
                                Text("\(Int(day.high.rounded()))°").font(.system(size: 11).monospacedDigit())
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func weekday(_ isoDate: String) -> String {
        guard let date = try? Date.ISO8601FormatStyle().year().month().day().parse(isoDate) else { return "" }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
    }
}

// MARK: - System

struct SystemMonitorWidget: View {
    let controller: DesktopController
    @Environment(\.desktopTheme) private var theme
    @Environment(\.widgetsAreLive) private var isLive
    @Environment(\.desktopStyle) private var style

    private var monitor: PanelSystemMonitor { controller.systemMonitor }
    private var disk: DiskUsageMonitor { controller.widgets.disk }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(title: "System", symbol: "gauge.with.dots.needle.33percent")
            meter("CPU", value: monitor.cpuUsage)
            meter("Memory", value: monitor.memoryUsage)
            meter("Disk", value: disk.usage?.fraction,
                  detail: disk.usage.map { ByteCountFormatter.string(fromByteCount: $0.usedBytes, countStyle: .file) })
            Spacer(minLength: 0)
            if let engine = controller.cpuEngine {
                Label(engine.title, systemImage: engine == .nativeJIT ? "bolt.fill" : "tortoise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(engine == .nativeJIT ? Color.green : theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .task(id: isLive) {
            guard isLive else { return }
            await disk.poll(controller.host)
        }
        .task(id: isLive && style != .ish) {
            // Only the iSH panel (PanelView) feeds the CPU and memory meters; elsewhere the
            // widget has to.
            guard isLive, style != .ish else { return }
            await monitor.poll(controller.host)
        }
    }

    private func meter(_ title: String, value: Double?, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(detail.map { "\($0) · " } ?? "")
                    .font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                + Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.primaryText.opacity(0.1))
                    Capsule().fill(color(for: value ?? 0))
                        .frame(width: proxy.size.width * CGFloat(min(max(value ?? 0, 0), 1)))
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .combine)
    }

    private func color(for value: Double) -> Color {
        if value > 0.85 { return theme.urgent }
        if value > 0.6 { return Color(red: 0.98, green: 0.72, blue: 0.3) }
        return theme.accent
    }
}

struct NowPlayingWidget: View {
    let center: NowPlayingCenter
    @Environment(\.widgetsAreLive) private var isLive

    var body: some View {
        Group {
            if isLive {
                NowPlayingCard(center: center, isCompact: true)
            } else {
                Color.clear
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct BatteryWidget: View {
    let status: SystemStatus
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(theme.primaryText.opacity(0.1), lineWidth: 7)
                Circle().trim(from: 0, to: CGFloat(status.batteryLevel ?? 0))
                    .stroke(levelColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: status.batteryState == .charging || status.batteryState == .full ? "bolt.fill" : "ipad.landscape")
                    .font(.system(size: 18, weight: .semibold))
            }
            .padding(6)
            Text(status.batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { status.start() }
        .onDisappear { status.stop() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Battery")
    }

    private var levelColor: Color {
        guard let level = status.batteryLevel else { return theme.secondaryText }
        if status.batteryState == .charging { return .green }
        return level < 0.2 ? theme.urgent : theme.accent
    }
}

struct NetworkWidget: View {
    let status: SystemStatus
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.network.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(status.network == .offline ? theme.secondaryText : theme.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.network.title).font(.system(size: 15, weight: .semibold))
                Text(status.network == .offline ? "Linux apps are offline" : "Linux apps are online")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .onAppear { status.start() }
        .onDisappear { status.stop() }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Notes

struct NotesWidget: View {
    let text: String
    let onChange: (String) -> Void
    @State private var draft = ""
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        TextEditor(text: $draft)
            .scrollContentBackground(.hidden)
            .font(.system(size: 13))
            .foregroundStyle(theme.primaryText)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Note")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { draft = text }
            .onChange(of: draft) { _, value in if value != text { onChange(value) } }
            .accessibilityIdentifier("widget.notes.text")
    }
}

struct WidgetHeader: View {
    let title: String
    let symbol: String
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
    }
}
