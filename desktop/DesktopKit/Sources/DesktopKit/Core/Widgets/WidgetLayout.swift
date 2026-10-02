import CoreGraphics
import Foundation

enum DesktopWidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case clock, calendar, weather, systemMonitor, nowPlaying, notes, battery, network, upcomingEvents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock: "Clock"
        case .calendar: "Calendar"
        case .weather: "Weather"
        case .systemMonitor: "System Monitor"
        case .nowPlaying: "Now Playing"
        case .notes: "Notes"
        case .battery: "Battery"
        case .network: "Network"
        case .upcomingEvents: "Upcoming Events"
        }
    }

    var symbol: String {
        switch self {
        case .clock: "clock"
        case .calendar: "calendar"
        case .weather: "cloud.sun"
        case .systemMonitor: "gauge.with.dots.needle.33percent"
        case .nowPlaying: "music.note"
        case .notes: "note.text"
        case .battery: "battery.75percent"
        case .network: "wifi"
        case .upcomingEvents: "list.bullet.rectangle"
        }
    }

    /// Sizes in grid cells: default, smallest and largest.
    var defaultSize: WidgetSize {
        switch self {
        case .clock: WidgetSize(width: 4, height: 4)
        case .calendar: WidgetSize(width: 6, height: 7)
        case .weather: WidgetSize(width: 5, height: 4)
        case .systemMonitor: WidgetSize(width: 5, height: 4)
        case .nowPlaying: WidgetSize(width: 8, height: 3)
        case .notes: WidgetSize(width: 5, height: 5)
        case .battery: WidgetSize(width: 3, height: 3)
        case .network: WidgetSize(width: 4, height: 3)
        case .upcomingEvents: WidgetSize(width: 6, height: 5)
        }
    }

    var minimumSize: WidgetSize {
        switch self {
        case .clock, .notes, .battery: WidgetSize(width: 3, height: 3)
        case .calendar: WidgetSize(width: 5, height: 6)
        case .weather, .systemMonitor, .upcomingEvents: WidgetSize(width: 4, height: 3)
        case .nowPlaying: WidgetSize(width: 6, height: 2)
        case .network: WidgetSize(width: 3, height: 2)
        }
    }

    var maximumSize: WidgetSize {
        switch self {
        case .clock, .network: WidgetSize(width: 6, height: 6)
        case .calendar, .weather, .systemMonitor, .upcomingEvents: WidgetSize(width: 9, height: 10)
        case .nowPlaying: WidgetSize(width: 12, height: 4)
        case .notes: WidgetSize(width: 12, height: 12)
        case .battery: WidgetSize(width: 5, height: 4)
        }
    }
}

struct WidgetSize: Codable, Equatable, Hashable, Sendable {
    var width: Int
    var height: Int
}

/// A widget's place on the desktop grid, in cells from the top-left corner.
struct WidgetFrame: Codable, Equatable, Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var size: WidgetSize { WidgetSize(width: width, height: height) }

    func intersects(_ other: WidgetFrame) -> Bool {
        x < other.x + other.width && other.x < x + width && y < other.y + other.height && other.y < y + height
    }
}

struct DesktopWidget: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: DesktopWidgetKind
    var frame: WidgetFrame
    /// Per-widget settings: the clock's face, a note's text.
    var options: [String: String] = [:]
}

/// The desktop's grid: cells of `cell` points, as many as fit the desktop area.
struct WidgetGrid: Equatable {
    static let cell: CGFloat = 40
    static let margin: CGFloat = 12

    var columns: Int
    var rows: Int

    init(columns: Int, rows: Int) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
    }

    init(size: CGSize) {
        self.init(columns: Int((size.width - Self.margin * 2) / Self.cell),
                  rows: Int((size.height - Self.margin * 2) / Self.cell))
    }

    /// Where a frame draws. A frame saved on a larger screen is pulled back inside this one,
    /// without changing what is saved.
    func rect(for frame: WidgetFrame) -> CGRect {
        let fitted = clamp(frame)
        return CGRect(x: Self.margin + CGFloat(fitted.x) * Self.cell, y: Self.margin + CGFloat(fitted.y) * Self.cell,
                      width: CGFloat(fitted.width) * Self.cell, height: CGFloat(fitted.height) * Self.cell)
    }

    /// The nearest cell to a widget's top-left corner at `point`.
    func cell(at point: CGPoint) -> (x: Int, y: Int) {
        (Int(((point.x - Self.margin) / Self.cell).rounded()), Int(((point.y - Self.margin) / Self.cell).rounded()))
    }

    func clamp(_ frame: WidgetFrame) -> WidgetFrame {
        var result = frame
        result.width = min(max(frame.width, 1), columns)
        result.height = min(max(frame.height, 1), rows)
        result.x = min(max(frame.x, 0), columns - result.width)
        result.y = min(max(frame.y, 0), rows - result.height)
        return result
    }

    /// The first free spot for `size`, scanning columns from the right edge (desktop icons
    /// fill from the left), top to bottom; the top-right corner when nothing is free.
    func freeSpot(for size: WidgetSize, avoiding frames: [WidgetFrame]) -> WidgetFrame {
        let width = min(size.width, columns), height = min(size.height, rows)
        for x in stride(from: columns - width, through: 0, by: -1) {
            for y in 0...(rows - height) {
                let candidate = WidgetFrame(x: x, y: y, width: width, height: height)
                if !frames.contains(where: { $0.intersects(candidate) }) { return candidate }
            }
        }
        return WidgetFrame(x: columns - width, y: 0, width: width, height: height)
    }
}

/// Every widget, either one set for the whole desktop or one set per workspace.
struct WidgetBoard: Codable, Equatable {
    enum Scope: String, Codable, Sendable {
        case global, perWorkspace
    }

    var scope = Scope.global
    var global: [DesktopWidget] = []
    /// Keyed by workspace index as a string, for JSON.
    var workspaces: [String: [DesktopWidget]] = [:]

    func widgets(workspace: Int) -> [DesktopWidget] {
        scope == .global ? global : workspaces[String(workspace)] ?? []
    }

    mutating func modify(workspace: Int, _ change: (inout [DesktopWidget]) -> Void) {
        if scope == .global {
            change(&global)
        } else {
            change(&workspaces[String(workspace), default: []])
        }
    }

    /// Switching keeps what is on screen: the current set becomes the global set, or the
    /// global set becomes the current workspace's.
    mutating func setScope(_ scope: Scope, currentWorkspace: Int) {
        guard scope != self.scope else { return }
        let current = widgets(workspace: currentWorkspace)
        self.scope = scope
        switch scope {
        case .global: global = current
        case .perWorkspace: workspaces[String(currentWorkspace)] = current
        }
    }

    @discardableResult
    mutating func add(_ kind: DesktopWidgetKind, workspace: Int, grid: WidgetGrid) -> DesktopWidget {
        let frames = widgets(workspace: workspace).map { grid.clamp($0.frame) }
        let widget = DesktopWidget(kind: kind, frame: grid.freeSpot(for: kind.defaultSize, avoiding: frames))
        modify(workspace: workspace) { $0.append(widget) }
        return widget
    }

    mutating func remove(_ id: UUID, workspace: Int) {
        modify(workspace: workspace) { $0.removeAll { $0.id == id } }
    }

    /// Moves to the cell and brings the widget to the front.
    mutating func move(_ id: UUID, toX x: Int, y: Int, workspace: Int, grid: WidgetGrid) {
        modify(workspace: workspace) { widgets in
            guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
            var widget = widgets.remove(at: index)
            widget.frame = grid.clamp(WidgetFrame(x: x, y: y, width: widget.frame.width, height: widget.frame.height))
            widgets.append(widget)
        }
    }

    /// Resizes within the kind's limits and the grid, keeping the top-left corner.
    mutating func resize(_ id: UUID, to size: WidgetSize, workspace: Int, grid: WidgetGrid) {
        modify(workspace: workspace) { widgets in
            guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
            let kind = widgets[index].kind
            let width = min(max(size.width, kind.minimumSize.width), kind.maximumSize.width)
            let height = min(max(size.height, kind.minimumSize.height), kind.maximumSize.height)
            let origin = grid.clamp(widgets[index].frame)
            widgets[index].frame = grid.clamp(WidgetFrame(x: origin.x, y: origin.y, width: width, height: height))
        }
    }

    mutating func setOption(_ key: String, _ value: String?, for id: UUID, workspace: Int) {
        modify(workspace: workspace) { widgets in
            guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
            widgets[index].options[key] = value
        }
    }

    static let storageKey = "desktop.widgets"
    /// Launch argument for UI tests: start with no widgets.
    static let resetKey = "desktop.resetWidgets"

    static func load(from defaults: UserDefaults = .standard) -> WidgetBoard {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(WidgetBoard.self, from: $0) } ?? WidgetBoard()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}
