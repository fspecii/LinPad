import CoreGraphics

/// Where a window can be tiled. Halves and quarters are remembered on the window so they
/// follow the desktop when it resizes; maximize is tracked separately (`isMaximized`).
enum SnapZone: String, Codable, CaseIterable, Sendable {
    case leftHalf
    case rightHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case maximize
}

enum ResizeEdge: CaseIterable, Sendable {
    case left
    case right
    case top
    case bottom
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var movesMinX: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesMaxX: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesMinY: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesMaxY: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
}

/// The window manager's pure geometry, kept free of state so it can be unit tested.
/// All rectangles are in desktop coordinates: the area below the panel, origin top-left.
enum WindowGeometry {
    struct Limits: Equatable, Sendable {
        var minimumSize = CGSize(width: 320, height: 200)
        var titleBarHeight: CGFloat = 40
        /// How much of a window must stay on screen horizontally to be grabbed again.
        var minimumVisibleWidth: CGFloat = 96
        /// Keeps title bars out of the strip where iPadOS's home gesture starts.
        var bottomGestureInset: CGFloat = 24
    }

    struct SnapSensitivity: Equatable, Sendable {
        /// Distance from a screen edge that counts as touching it.
        var edgeThreshold: CGFloat = 20
        /// Along an edge, the end segment that snaps to a quarter instead of a half.
        var cornerBand: CGFloat = 72
    }

    static func frame(for zone: SnapZone, in bounds: CGSize) -> CGRect {
        let halfWidth = (bounds.width / 2).rounded()
        let halfHeight = (bounds.height / 2).rounded()
        let left = CGRect(x: 0, y: 0, width: halfWidth, height: bounds.height)
        let right = CGRect(x: halfWidth, y: 0, width: bounds.width - halfWidth, height: bounds.height)
        switch zone {
        case .maximize: return CGRect(origin: .zero, size: bounds)
        case .leftHalf: return left
        case .rightHalf: return right
        case .topLeft: return CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight)
        case .topRight: return CGRect(x: halfWidth, y: 0, width: right.width, height: halfHeight)
        case .bottomLeft: return CGRect(x: 0, y: halfHeight, width: halfWidth, height: bounds.height - halfHeight)
        case .bottomRight: return CGRect(x: halfWidth, y: halfHeight, width: right.width,
                                         height: bounds.height - halfHeight)
        }
    }

    /// The zone a window dragged with the pointer at `pointer` would snap to: the top edge
    /// maximizes, the side edges take a half, and the ends of either edge take a quarter.
    static func snapZone(at pointer: CGPoint, in bounds: CGSize,
                         sensitivity: SnapSensitivity = SnapSensitivity()) -> SnapZone? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let threshold = sensitivity.edgeThreshold
        let band = min(sensitivity.cornerBand, bounds.height / 4, bounds.width / 4)
        let atLeft = pointer.x <= threshold
        let atRight = pointer.x >= bounds.width - threshold
        let atTop = pointer.y <= threshold

        if atLeft || atRight {
            if pointer.y <= band { return atLeft ? .topLeft : .topRight }
            if pointer.y >= bounds.height - band { return atLeft ? .bottomLeft : .bottomRight }
            return atLeft ? .leftHalf : .rightHalf
        }
        if atTop {
            if pointer.x <= band { return .topLeft }
            if pointer.x >= bounds.width - band { return .topRight }
            return .maximize
        }
        return nil
    }

    /// Keeps a floating window grabbable: no larger than the desktop, enough of its width on
    /// screen, and its title bar between the top edge and the home-gesture strip.
    static func clamped(_ frame: CGRect, in bounds: CGSize, limits: Limits = Limits()) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return frame }
        var result = frame
        result.size.width = min(max(frame.width, limits.minimumSize.width),
                                max(bounds.width, limits.minimumSize.width))
        result.size.height = min(max(frame.height, limits.minimumSize.height),
                                 max(bounds.height, limits.minimumSize.height))
        let visible = min(limits.minimumVisibleWidth, result.width)
        result.origin.x = min(max(frame.minX, visible - result.width), bounds.width - visible)
        let lowestTitleBar = max(0, bounds.height - limits.titleBarHeight - limits.bottomGestureInset)
        result.origin.y = min(max(frame.minY, 0), lowestTitleBar)
        return result.integral
    }

    /// The frame after dragging `edge` by `translation`, never smaller than the minimum size
    /// and never past the desktop's edges. The opposite edges stay put.
    static func resized(_ origin: CGRect, edge: ResizeEdge, translation: CGSize,
                        in bounds: CGSize, limits: Limits = Limits()) -> CGRect {
        let minSize = limits.minimumSize
        var minX = origin.minX, maxX = origin.maxX, minY = origin.minY, maxY = origin.maxY
        if edge.movesMinX {
            minX = min(max(origin.minX + translation.width, 0), origin.maxX - minSize.width)
        }
        if edge.movesMaxX {
            maxX = max(min(origin.maxX + translation.width, max(bounds.width, origin.minX + minSize.width)),
                       origin.minX + minSize.width)
        }
        if edge.movesMinY {
            minY = min(max(origin.minY + translation.height, 0), origin.maxY - minSize.height)
        }
        if edge.movesMaxY {
            maxY = max(min(origin.maxY + translation.height, max(bounds.height, origin.minY + minSize.height)),
                       origin.minY + minSize.height)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }

    /// Lifts (and if need be shortens) a frame so it ends above the on-screen keyboard.
    static func avoidingKeyboard(_ frame: CGRect, availableHeight: CGFloat, minimumHeight: CGFloat) -> CGRect {
        guard availableHeight > 0, frame.maxY > availableHeight else { return frame }
        var result = frame
        result.size.height = max(min(frame.height, availableHeight), min(minimumHeight, availableHeight))
        result.origin.y = max(0, availableHeight - result.height)
        return result
    }

    static func centered(_ frame: CGRect, in bounds: CGSize) -> CGRect {
        CGRect(x: ((bounds.width - frame.width) / 2).rounded(),
               y: ((bounds.height - frame.height) / 2).rounded(),
               width: frame.width, height: frame.height)
    }

    static let placementMargin: CGFloat = 16
    static let cascadeStep: CGFloat = 28

    /// The size a new window opens at. In landscape the default never exceeds half the
    /// desktop, so two fresh windows fit side by side on an 11" iPad.
    static func initialSize(preferred: CGSize, in bounds: CGSize, limits: Limits = Limits()) -> CGSize {
        guard bounds.width > 0, bounds.height > 0 else { return preferred }
        let margin = placementMargin
        var maxWidth = bounds.width - margin * 2
        if bounds.width > bounds.height {
            maxWidth = min(maxWidth, ((bounds.width - margin * 3) / 2).rounded(.down))
        }
        let maxHeight = bounds.height - margin * 2 - limits.bottomGestureInset
        return CGSize(width: max(limits.minimumSize.width, min(preferred.width, maxWidth)),
                      height: max(limits.minimumSize.height, min(preferred.height, maxHeight)))
    }

    /// Where a new window goes: the left or right column if that column is free, otherwise
    /// a cascade from the most recently placed window.
    static func placement(for size: CGSize, avoiding existing: [CGRect], in bounds: CGSize,
                          limits: Limits = Limits()) -> CGRect {
        let margin = placementMargin
        let top = max(margin * 0.5, ((bounds.height - limits.bottomGestureInset - size.height) / 2).rounded() - 40)
        let columns = [
            CGRect(x: margin, y: top, width: size.width, height: size.height),
            CGRect(x: bounds.width - margin - size.width, y: top, width: size.width, height: size.height),
        ]
        if bounds.width >= size.width * 2 + margin * 3 {
            if let free = columns.first(where: { column in
                !existing.contains { $0.intersection(column).width > column.width * 0.25 }
            }) {
                return clamped(free, in: bounds, limits: limits)
            }
        }
        let anchor = existing.last.map { $0.origin } ?? CGPoint(x: margin, y: top)
        var origin = CGPoint(x: anchor.x + cascadeStep, y: anchor.y + cascadeStep)
        if origin.x + size.width > bounds.width - margin || origin.y + size.height > bounds.height - margin {
            origin = CGPoint(x: margin + cascadeStep * CGFloat(existing.count % 4), y: margin * 0.5)
        }
        return clamped(CGRect(origin: origin, size: size), in: bounds, limits: limits)
    }

    /// Exposé layout: windows keep their aspect ratio and relative order in a grid whose
    /// column count best fills `area`. Never scales a window up.
    static func overviewLayout(for frames: [CGRect], in area: CGRect, spacing: CGFloat = 28) -> [CGRect] {
        guard !frames.isEmpty, area.width > 0, area.height > 0 else { return [] }
        var best: (scale: CGFloat, columns: Int) = (0, 1)
        for columns in 1...frames.count {
            let rows = Int((Double(frames.count) / Double(columns)).rounded(.up))
            let cellWidth = (area.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let cellHeight = (area.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            guard cellWidth > 0, cellHeight > 0 else { continue }
            let scale = frames.map { min(cellWidth / $0.width, cellHeight / $0.height, 1) }.min() ?? 0
            if scale > best.scale { best = (scale, columns) }
        }
        let columns = best.columns
        let rows = Int((Double(frames.count) / Double(columns)).rounded(.up))
        let cellWidth = (area.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (area.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        return frames.enumerated().map { index, frame in
            let row = index / columns
            let column = index % columns
            let itemsInRow = row == rows - 1 ? frames.count - row * columns : columns
            let rowInset = (CGFloat(columns - itemsInRow) * (cellWidth + spacing)) / 2
            let scale = min(cellWidth / frame.width, cellHeight / frame.height, 1)
            let size = CGSize(width: frame.width * scale, height: frame.height * scale)
            let cellX = area.minX + rowInset + CGFloat(column) * (cellWidth + spacing)
            let cellY = area.minY + CGFloat(row) * (cellHeight + spacing)
            return CGRect(x: cellX + (cellWidth - size.width) / 2, y: cellY + (cellHeight - size.height) / 2,
                          width: size.width, height: size.height)
        }
    }
}

/// How a tiling workspace arranges its windows.
enum TilingLayout: String, Codable, CaseIterable, Sendable {
    /// The first window takes the master column; the rest stack on the right.
    case masterStack
    /// Equal columns side by side.
    case columns
    /// The most even grid; a short last row stretches to fill.
    case grid
    /// Every window full size, the focused one on top.
    case monocle

    var title: String {
        switch self {
        case .masterStack: "Master and Stack"
        case .columns: "Columns"
        case .grid: "Grid"
        case .monocle: "Monocle"
        }
    }

    var symbol: String {
        switch self {
        case .masterStack: "rectangle.split.2x1"
        case .columns: "rectangle.split.3x1"
        case .grid: "square.grid.2x2"
        case .monocle: "rectangle"
        }
    }
}

extension WindowGeometry {
    static let masterRatioRange: ClosedRange<CGFloat> = 0.2...0.8

    /// Tile frames for `count` windows in tiling order. `gap` separates tiles from each other
    /// and from the desktop's edges.
    /// `gap` separates tiles; `outerGap` (default: the same) keeps them off the screen edge.
    static func tileFrames(count: Int, layout: TilingLayout, in bounds: CGSize, gap: CGFloat,
                           outerGap: CGFloat? = nil, masterRatio: CGFloat = 0.5) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let outer = outerGap ?? gap
        let area = CGRect(origin: .zero, size: bounds).insetBy(dx: outer, dy: outer)
        func column(_ rect: CGRect, rows: Int) -> [CGRect] {
            let height = (rect.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            return (0..<rows).map { row in
                CGRect(x: rect.minX, y: rect.minY + CGFloat(row) * (height + gap), width: rect.width, height: height)
            }
        }
        func row(_ rect: CGRect, columns: Int) -> [CGRect] {
            let width = (rect.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            return (0..<columns).map { index in
                CGRect(x: rect.minX + CGFloat(index) * (width + gap), y: rect.minY, width: width, height: rect.height)
            }
        }

        let frames: [CGRect]
        switch layout {
        case .monocle:
            frames = Array(repeating: area, count: count)
        case .columns:
            frames = row(area, columns: count)
        case .masterStack:
            guard count > 1 else { return [area.integral] }
            let ratio = min(max(masterRatio, masterRatioRange.lowerBound), masterRatioRange.upperBound)
            let masterWidth = ((area.width - gap) * ratio).rounded()
            let master = CGRect(x: area.minX, y: area.minY, width: masterWidth, height: area.height)
            let stack = CGRect(x: master.maxX + gap, y: area.minY, width: area.width - masterWidth - gap,
                               height: area.height)
            frames = [master] + column(stack, rows: count - 1)
        case .grid:
            let columns = Int(Double(count).squareRoot().rounded(.up))
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let rowRects = column(area, rows: rows)
            frames = rowRects.enumerated().flatMap { index, rect in
                row(rect, columns: min(columns, count - index * columns))
            }
        }
        return frames.map(\.integral)
    }

    /// The master ratio that puts the split between master and stack at `x`.
    static func masterRatio(forSplitAt x: CGFloat, in bounds: CGSize, gap: CGFloat, outerGap: CGFloat? = nil) -> CGFloat {
        let outer = outerGap ?? gap
        let usable = bounds.width - outer * 2 - gap
        guard usable > 0 else { return 0.5 }
        let ratio = (x - outer) / usable
        return min(max(ratio, masterRatioRange.lowerBound), masterRatioRange.upperBound)
    }

    /// The tile nearest to `from` in the direction `(dx, dy)` (each -1, 0 or 1), judged by
    /// tile centers; nil when nothing lies that way.
    static func neighbor(of from: CGRect, in tiles: [CGRect], dx: Int, dy: Int) -> Int? {
        let origin = CGPoint(x: from.midX, y: from.midY)
        var best: (index: Int, score: CGFloat)?
        for (index, tile) in tiles.enumerated() where tile != from {
            let delta = CGPoint(x: tile.midX - origin.x, y: tile.midY - origin.y)
            let along = delta.x * CGFloat(dx) + delta.y * CGFloat(dy)
            guard along > 1 else { continue }
            let across = abs(delta.x * CGFloat(dy)) + abs(delta.y * CGFloat(dx))
            let score = along + across * 2
            if best == nil || score < best!.score { best = (index, score) }
        }
        return best?.index
    }
}
