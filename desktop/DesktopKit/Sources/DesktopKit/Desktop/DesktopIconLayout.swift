import CoreGraphics
import Foundation

/// Desktop icon size (Settings > Desktop, or the desktop menu).
enum DesktopIconSize: String, CaseIterable, Codable, Identifiable, Sendable {
    case small, medium, large

    static let storageKey = "desktop.icons.size"

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var cellSize: CGSize {
        switch self {
        case .small: CGSize(width: 80, height: 84)
        case .medium: CGSize(width: 96, height: 100)
        case .large: CGSize(width: 120, height: 124)
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .small: 40
        case .medium: 52
        case .large: 68
        }
    }
}

/// How "Arrange Icons" and "Keep Arranged" order the desktop.
enum DesktopArrangeKey: String, CaseIterable, Codable, Sendable {
    case name, type, date

    var title: String {
        switch self {
        case .name: "Name"
        case .type: "Type"
        case .date: "Date Modified"
        }
    }
}

/// Where desktop icons sit. With snap to grid, icons own cells filled column by column from
/// the top-left, as on XFCE; without it, icons keep free positions. Either way icons never
/// overlap: a move onto an occupied spot takes the nearest free one. Icons the user moved
/// keep their place (persisted per style and screen size); new icons take the first free
/// cell; icons that fell off a smaller screen are placed again.
struct DesktopIconLayout: Equatable {
    struct Cell: Hashable, Codable {
        var column: Int
        var row: Int
    }

    static let inset: CGFloat = 16
    /// The medium size's cell, for code that only needs a typical size.
    static let cellSize = DesktopIconSize.medium.cellSize

    var cells: [String: Cell] = [:]
    /// Top-left corners of icons placed freely (snap to grid off).
    var free: [String: CGPoint] = [:]
    var iconSize = DesktopIconSize.medium
    var snapsToGrid = true
    /// Re-arranged by this key whenever icons come and go.
    var keepsArranged: DesktopArrangeKey?

    var cellSize: CGSize { iconSize.cellSize }

    func rows(in size: CGSize) -> Int {
        max(1, Int((size.height - Self.inset * 2) / cellSize.height))
    }

    func columns(in size: CGSize) -> Int {
        max(1, Int((size.width - Self.inset * 2) / cellSize.width))
    }

    func origin(of cell: Cell) -> CGPoint {
        CGPoint(x: Self.inset + CGFloat(cell.column) * cellSize.width, y: Self.inset + CGFloat(cell.row) * cellSize.height)
    }

    /// The cell under a point, clamped to the visible grid.
    func cell(at point: CGPoint, in size: CGSize) -> Cell {
        let column = Int(((point.x - Self.inset) / cellSize.width).rounded(.down))
        let row = Int(((point.y - Self.inset) / cellSize.height).rounded(.down))
        return Cell(column: max(0, min(columns(in: size) - 1, column)), row: max(0, min(rows(in: size) - 1, row)))
    }

    /// Cells for `keys` in order: saved ones first, the rest filling free cells.
    func resolved(_ keys: [String], in size: CGSize) -> [String: Cell] {
        let rows = rows(in: size)
        let columns = columns(in: size)
        var result: [String: Cell] = [:]
        var used = Set<Cell>()
        for key in keys {
            guard let cell = cells[key], cell.row < rows, cell.column < columns, !used.contains(cell) else { continue }
            result[key] = cell
            used.insert(cell)
        }
        var next = 0
        for key in keys where result[key] == nil {
            var cell = Cell(column: next / rows, row: next % rows)
            while used.contains(cell) {
                next += 1
                cell = Cell(column: next / rows, row: next % rows)
            }
            result[key] = cell
            used.insert(cell)
            next += 1
        }
        return result
    }

    /// Final top-left corners: grid cells, or free positions that are on screen and clear of
    /// other icons (anything else falls back to its grid cell).
    func positions(_ keys: [String], in size: CGSize) -> [String: CGPoint] {
        let grid = resolved(keys, in: size)
        guard !snapsToGrid else { return grid.mapValues(origin(of:)) }
        var result: [String: CGPoint] = [:]
        var placed: [CGRect] = []
        let bounds = CGRect(origin: .zero, size: size)
        for key in keys {
            if let point = free[key] {
                let rect = CGRect(origin: point, size: cellSize)
                if bounds.contains(rect), !placed.contains(where: { $0.insetBy(dx: 4, dy: 4).intersects(rect) }) {
                    result[key] = point
                    placed.append(rect)
                    continue
                }
            }
            let point = nearestFreeSpot(to: grid[key].map(origin(of:)) ?? .zero, avoiding: placed, in: size)
            result[key] = point
            placed.append(CGRect(origin: point, size: cellSize))
        }
        return result
    }

    /// Moves icons so the first lands on `target` and the rest follow in column order,
    /// skipping cells other icons hold.
    mutating func move(_ keys: [String], to target: Cell, allKeys: [String], in size: CGSize) {
        let rows = rows(in: size)
        var current = resolved(allKeys, in: size)
        let moving = Set(keys)
        let occupied = Set(current.filter { !moving.contains($0.key) }.map(\.value))
        var index = target.column * rows + target.row
        for key in keys {
            var cell = Cell(column: index / rows, row: index % rows)
            while occupied.contains(cell) {
                index += 1
                cell = Cell(column: index / rows, row: index % rows)
            }
            current[key] = cell
            index += 1
        }
        for key in allKeys { cells[key] = current[key] }
        keepsArranged = nil
    }

    /// Moves a group by `translation`: snapped to cells with snap to grid, otherwise to the
    /// nearest spots where nothing overlaps. Relative positions within the group are kept.
    mutating func drag(_ keys: [String], by translation: CGSize, allKeys: [String], in size: CGSize) {
        let current = positions(allKeys, in: size)
        let moving = keys.filter { current[$0] != nil }
        guard !moving.isEmpty else { return }
        if snapsToGrid {
            let ordered = moving.sorted { lhs, rhs in
                let a = current[lhs]!, b = current[rhs]!
                return a.x == b.x ? a.y < b.y : a.x < b.x
            }
            let leader = current[ordered[0]]!
            let target = cell(at: CGPoint(x: leader.x + translation.width + cellSize.width / 2,
                                          y: leader.y + translation.height + cellSize.height / 2), in: size)
            move(ordered, to: target, allKeys: allKeys, in: size)
            return
        }
        var placed = allKeys.filter { !moving.contains($0) }.compactMap { current[$0] }
            .map { CGRect(origin: $0, size: cellSize) }
        for key in moving {
            let start = current[key]!
            let wanted = CGPoint(x: start.x + translation.width, y: start.y + translation.height)
            let point = nearestFreeSpot(to: wanted, avoiding: placed, in: size)
            free[key] = point
            placed.append(CGRect(origin: point, size: cellSize))
        }
        for key in allKeys where free[key] == nil { free[key] = current[key] }
        keepsArranged = nil
    }

    /// Lays icons out again in the given order, forgetting manual placement.
    mutating func arrange(_ keys: [String], in size: CGSize) {
        let rows = rows(in: size)
        cells = Dictionary(uniqueKeysWithValues: keys.enumerated().map { index, key in
            (key, Cell(column: index / rows, row: index % rows))
        })
        free = [:]
    }

    /// "Align to Grid": free icons move to the nearest unused cells.
    mutating func alignToGrid(_ keys: [String], in size: CGSize) {
        let current = positions(keys, in: size)
        var used = Set<Cell>()
        var aligned: [String: Cell] = [:]
        let order = keys.sorted { (current[$0]?.x ?? 0, current[$0]?.y ?? 0) < (current[$1]?.x ?? 0, current[$1]?.y ?? 0) }
        for key in order {
            let point = current[key] ?? .zero
            var cell = self.cell(at: CGPoint(x: point.x + cellSize.width / 2, y: point.y + cellSize.height / 2), in: size)
            let rows = rows(in: size)
            var index = cell.column * rows + cell.row
            while used.contains(cell) {
                index += 1
                cell = Cell(column: index / rows, row: index % rows)
            }
            aligned[key] = cell
            used.insert(cell)
        }
        cells = aligned
        free = [:]
    }

    /// The closest point to `target` (searched outward in 12 pt steps) where an icon fits on
    /// screen without overlapping `others`.
    func nearestFreeSpot(to target: CGPoint, avoiding others: [CGRect], in size: CGSize) -> CGPoint {
        let maxX = max(0, size.width - cellSize.width)
        let maxY = max(0, size.height - cellSize.height)
        func clamp(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x, 0), maxX), y: min(max(point.y, 0), maxY))
        }
        func fits(_ point: CGPoint) -> Bool {
            let rect = CGRect(origin: point, size: cellSize).insetBy(dx: 4, dy: 4)
            return !others.contains { $0.intersects(rect) }
        }
        let start = clamp(target)
        if fits(start) { return start }
        let step: CGFloat = 12
        for ring in 1...200 {
            let radius = CGFloat(ring) * step
            var candidates: [CGPoint] = []
            for i in -ring...ring {
                let offset = CGFloat(i) * step
                candidates += [CGPoint(x: start.x + offset, y: start.y - radius), CGPoint(x: start.x + offset, y: start.y + radius),
                               CGPoint(x: start.x - radius, y: start.y + offset), CGPoint(x: start.x + radius, y: start.y + offset)]
            }
            let best = candidates.map(clamp).filter(fits)
                .min { hypot($0.x - target.x, $0.y - target.y) < hypot($1.x - target.x, $1.y - target.y) }
            if let best { return best }
        }
        return start
    }

    // MARK: - Persistence

    static let storageKey = "desktop.icons.cells"
    /// Launch argument that starts with the default layout (UI tests).
    static let resetArgument = "desktop.resetIcons"

    private struct Stored: Codable {
        var cells: [String: Cell]
        var free: [String: CGPoint]?
        var snapsToGrid: Bool?
        var keepsArranged: DesktopArrangeKey?
    }

    /// Layouts are kept per style and desktop size, so landscape, portrait and each style
    /// remember their own arrangement.
    static func key(context: String?) -> String {
        context.map { "\(storageKey).\($0)" } ?? storageKey
    }

    static func load(context: String? = nil, from defaults: UserDefaults = .standard) -> DesktopIconLayout {
        let size = defaults.string(forKey: DesktopIconSize.storageKey).flatMap(DesktopIconSize.init) ?? .medium
        let data = defaults.data(forKey: key(context: context)) ?? (context == nil ? nil : defaults.data(forKey: storageKey))
        guard let data else { return DesktopIconLayout(iconSize: size) }
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            return DesktopIconLayout(cells: stored.cells, free: stored.free ?? [:], iconSize: size,
                                     snapsToGrid: stored.snapsToGrid ?? true, keepsArranged: stored.keepsArranged)
        }
        let cells = (try? JSONDecoder().decode([String: Cell].self, from: data)) ?? [:]
        return DesktopIconLayout(cells: cells, iconSize: size)
    }

    func save(context: String? = nil, to defaults: UserDefaults = .standard) {
        let stored = Stored(cells: cells, free: free, snapsToGrid: snapsToGrid, keepsArranged: keepsArranged)
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key(context: context)) }
    }

    static func reset(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(storageKey) {
            defaults.removeObject(forKey: key)
        }
    }
}
