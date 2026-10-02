import Foundation
import Observation

/// The desktop's widgets: what is placed where, edit mode, and the shared data some of
/// them show (weather, disk usage).
@Observable @MainActor
final class DesktopWidgetStore {
    private(set) var board: WidgetBoard
    var isEditing = false {
        didSet { if !isEditing { selectedID = nil } }
    }
    /// The widget the keyboard moves in edit mode.
    var selectedID: UUID?
    /// The desktop area's grid, set by the widget layer as the area resizes.
    var grid = WidgetGrid(columns: 24, rows: 16)
    let weather = WeatherModel()
    let disk = DiskUsageMonitor()

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.bool(forKey: WidgetBoard.resetKey) {
            defaults.removeObject(forKey: WidgetBoard.storageKey)
        }
        board = WidgetBoard.load(from: defaults)
    }

    func widgets(workspace: Int) -> [DesktopWidget] {
        board.widgets(workspace: workspace)
    }

    @discardableResult
    func add(_ kind: DesktopWidgetKind, workspace: Int) -> DesktopWidget {
        let widget = change { $0.add(kind, workspace: workspace, grid: grid) }
        selectedID = widget.id
        return widget
    }

    func remove(_ id: UUID, workspace: Int) {
        change { $0.remove(id, workspace: workspace) }
        if selectedID == id { selectedID = nil }
    }

    func move(_ id: UUID, toX x: Int, y: Int, workspace: Int) {
        change { $0.move(id, toX: x, y: y, workspace: workspace, grid: grid) }
    }

    func nudge(_ id: UUID, dx: Int, dy: Int, workspace: Int) {
        guard let frame = widgets(workspace: workspace).first(where: { $0.id == id }).map({ grid.clamp($0.frame) }) else { return }
        move(id, toX: frame.x + dx, y: frame.y + dy, workspace: workspace)
    }

    func resize(_ id: UUID, to size: WidgetSize, workspace: Int) {
        change { $0.resize(id, to: size, workspace: workspace, grid: grid) }
    }

    func setOption(_ key: String, _ value: String?, for id: UUID, workspace: Int) {
        change { $0.setOption(key, value, for: id, workspace: workspace) }
    }

    var scope: WidgetBoard.Scope { board.scope }

    func setScope(_ scope: WidgetBoard.Scope, currentWorkspace: Int) {
        change { $0.setScope(scope, currentWorkspace: currentWorkspace) }
    }

    @discardableResult
    private func change<Result>(_ body: (inout WidgetBoard) -> Result) -> Result {
        let result = body(&board)
        board.save(to: defaults)
        return result
    }
}

/// `df` for the root filesystem, sampled once a minute while a System Monitor widget shows it.
@Observable @MainActor
final class DiskUsageMonitor {
    struct Usage: Equatable {
        var usedBytes: Int64
        var totalBytes: Int64

        var fraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    private(set) var usage: Usage?

    func poll(_ host: any LinuxHost) async {
        while !Task.isCancelled {
            let result = await host.run("df -Pk /")
            if result.succeeded, let usage = Self.parse(result.stdout) { self.usage = usage }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
        }
    }

    /// POSIX `df -Pk`: a header, then `filesystem 1024-blocks used available capacity mount`.
    nonisolated static func parse(_ text: String) -> Usage? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else { return nil }
        let fields = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4, let total = Int64(fields[1]), let used = Int64(fields[2]) else { return nil }
        return Usage(usedBytes: used * 1024, totalBytes: total * 1024)
    }
}
