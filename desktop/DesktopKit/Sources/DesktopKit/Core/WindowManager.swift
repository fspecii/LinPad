import SwiftUI
import Observation
import UIKit

/// One top-level window. A class so each `WindowView` observes only its own window,
/// which keeps a 120 Hz drag from invalidating every other window on the desktop.
@Observable @MainActor
final class DesktopWindow: Identifiable {
    let id = UUID()
    let appID: String
    let symbol: String
    /// What the app was opened with; session restore reopens it with the same arguments.
    let arguments: [String: String]
    var title: String
    /// The free-floating frame; maximized and snapped windows return to it.
    var frame: CGRect
    var zIndex: Int
    var workspace: Int
    var isMinimized = false
    var isMaximized = false
    var snap: SnapZone?
    var isAlwaysOnTop = false
    /// Kept out of its workspace's tiling layout, drawn at its floating frame above the tiles.
    var isFloating = false
    /// How far a tiled window has been dragged from its tile; it snaps back or swaps on release.
    var tileDragOffset: CGSize = .zero
    /// True while the user drags or resizes the window; chrome drops expensive effects.
    var isInteracting = false

    /// Built exactly once, so app state survives minimizing, workspace switches and re-renders.
    @ObservationIgnored var content = AnyView(EmptyView())
    /// Set when the app decides how to close (a Linux app may ask to save first);
    /// the app then closes the window itself.
    @ObservationIgnored var onCloseRequest: (() -> Void)?
    /// The last picture of the window taken while nothing covered it (window switcher).
    @ObservationIgnored var snapshot: UIImage?

    init(appID: String, symbol: String, title: String, arguments: [String: String] = [:],
         frame: CGRect, zIndex: Int, workspace: Int) {
        self.appID = appID
        self.symbol = symbol
        self.title = title
        self.arguments = arguments
        self.frame = frame
        self.zIndex = zIndex
        self.workspace = workspace
    }

    var isTiled: Bool { isMaximized || snap != nil }
}

/// Window chrome sizes for the input at hand.
struct WindowMetrics: Equatable, Sendable {
    var titleBarHeight: CGFloat
    /// Width and height of a title-bar button's hit area.
    var buttonSize: CGFloat
    var isTouch: Bool

    static let pointer = WindowMetrics(titleBarHeight: 40, buttonSize: 40, isTouch: false)
    /// Close to UKUI's tablet mode (64 pt bars, 48 pt buttons); 56 keeps more content on an
    /// 11" iPad in landscape while every control stays above 44 pt.
    static let touch = WindowMetrics(titleBarHeight: 56, buttonSize: 48, isTouch: true)
    static let tablet = WindowMetrics(titleBarHeight: 64, buttonSize: 48, isTouch: true)
}

struct SnapPreview: Equatable {
    let windowID: UUID
    let frame: CGRect
}

/// Where a restored window goes when its app opens it again.
struct WindowPlacement: Codable, Equatable {
    var frame: CGRect
    var workspace: Int
    var snap: SnapZone?
    var isMaximized: Bool
    var isMinimized: Bool
    var isAlwaysOnTop: Bool
    var isFloating: Bool? = nil
}

/// A workspace's auto-tiling settings, persisted per workspace.
struct TilingState: Codable, Equatable, Sendable {
    var isEnabled = false
    var layout = TilingLayout.masterStack
    var masterRatio: CGFloat = 0.5
}

@Observable @MainActor
final class WindowManager {
    /// Workspaces a fresh desktop starts with; the user can add up to `maximumWorkspaces`.
    static let defaultWorkspaceCount = 4
    static let maximumWorkspaces = 9
    /// Geometry limits for the current window metrics; the title bar grows in touch mode.
    private(set) static var limits = WindowGeometry.Limits()
    static var minimumSize: CGSize { limits.minimumSize }
    static var titleBarHeight: CGFloat { limits.titleBarHeight }

    /// Pointer metrics when a hardware keyboard or pointer is attached, touch metrics
    /// (taller title bars, 48 pt buttons) otherwise.
    private(set) var metrics = WindowMetrics.pointer
    var titleBarHeight: CGFloat { metrics.titleBarHeight }

    func setMetrics(_ metrics: WindowMetrics) {
        guard metrics != self.metrics else { return }
        self.metrics = metrics
        Self.limits.titleBarHeight = metrics.titleBarHeight
        for window in windows { window.frame = clamped(window.frame) }
    }
    /// Always-on-top windows stack above every normal window, floating windows above tiles.
    private static let alwaysOnTopBoost = 1_000_000
    private static let floatingBoost = 500_000

    private(set) var windows: [DesktopWindow] = []
    private(set) var focusedWindowID: UUID? {
        didSet { if focusedWindowID != oldValue { keyboard.focusChanged(to: focusedWindowID) } }
    }
    private(set) var currentWorkspace = 0
    /// Optional names, one per workspace ("" shows the number).
    private(set) var workspaceNames = Array(repeating: "", count: WindowManager.defaultWorkspaceCount)
    var workspaceCount: Int { workspaceNames.count }
    private(set) var snapPreview: SnapPreview?
    /// The area windows live in: the screen below the panel.
    private(set) var desktopSize: CGSize = .zero
    /// The on-screen keyboard and the window it lifts (see KeyboardAvoidance).
    private(set) var keyboard = KeyboardAvoidance()
    /// How far the on-screen keyboard reaches up into the desktop.
    var keyboardOverlap: CGFloat { keyboard.overlap }
    /// Per-workspace auto-tiling.
    private(set) var tiling = Array(repeating: TilingState(), count: WindowManager.defaultWorkspaceCount)
    /// Where each tiled window sits; windows absent here float.
    private(set) var tileFrames: [UUID: CGRect] = [:]
    /// Space between tiles; the screen edge gets twice as much (Omarchy's 5 / 10).
    var tilingGap: CGFloat = 5 {
        didSet { if tilingGap != oldValue { retileAll() } }
    }
    /// "Zen": no gaps, borders or rounding (⌃⌥⇧⌫).
    var isZen = false {
        didSet { if isZen != oldValue { retileAll() } }
    }
    var innerGap: CGFloat { isZen ? 0 : tilingGap }
    /// The screen-edge gap the user set in the Themes app; nil is twice the inner gap.
    var outerGapOverride: CGFloat? {
        didSet { if outerGapOverride != oldValue { retileAll() } }
    }
    var outerGap: CGFloat { isZen ? 0 : (outerGapOverride ?? tilingGap * 2) }
    /// Taskbar buttons in global coordinates, where minimized windows shrink to.
    var taskbarTargets: [UUID: CGRect] = [:]
    /// The desktop area's origin in global coordinates.
    @ObservationIgnored var desktopGlobalOrigin: CGPoint = .zero

    /// Called after any change worth persisting (session restore).
    @ObservationIgnored var onLayoutChange: (() -> Void)?
    /// Called just before the focused window loses focus, while it is still on top.
    @ObservationIgnored var willChangeFocus: ((DesktopWindow) -> Void)?

    @ObservationIgnored private var topZIndex = 0
    /// Most recently focused first; drives the window switcher.
    @ObservationIgnored private var focusHistory: [UUID] = []
    @ObservationIgnored private var pendingPlacements: [String: [WindowPlacement]] = [:]
    /// Tiling order across all workspaces; dragging one tile onto another swaps them here.
    @ObservationIgnored private var tileOrder: [UUID] = []
    /// Called when a workspace's tiling settings change, to persist them.
    @ObservationIgnored var onTilingChange: (([TilingState]) -> Void)?
    /// Workspaces were deleted or reordered: maps each surviving old index to its new one,
    /// so per-workspace settings elsewhere (wallpapers) follow.
    @ObservationIgnored var onWorkspacesRemapped: (([Int: Int]) -> Void)?

    var focusedWindow: DesktopWindow? {
        focusedWindowID.flatMap(window(withID:))
    }

    func window(withID id: UUID) -> DesktopWindow? {
        windows.first { $0.id == id }
    }

    func windowsInCurrentWorkspace() -> [DesktopWindow] {
        windows.filter { $0.workspace == currentWorkspace }
    }

    func windows(inWorkspace index: Int) -> [DesktopWindow] {
        windows.filter { $0.workspace == index }
    }

    func isVisible(_ window: DesktopWindow) -> Bool {
        window.workspace == currentWorkspace && !window.isMinimized
    }

    func stackingOrder(of window: DesktopWindow) -> Int {
        var order = window.zIndex
        if window.isAlwaysOnTop { order += Self.alwaysOnTopBoost }
        if window.isFloating && tiling[window.workspace].isEnabled { order += Self.floatingBoost }
        return order
    }

    /// True when the window's position comes from its workspace's tiling layout.
    func isTiledByLayout(_ window: DesktopWindow) -> Bool {
        tileFrames[window.id] != nil
    }

    /// Visible windows of the current workspace, topmost first.
    func visibleStack() -> [DesktopWindow] {
        windows.filter(isVisible).sorted { stackingOrder(of: $0) > stackingOrder(of: $1) }
    }

    /// Windows of the current workspace, most recently focused first; minimized ones last.
    func recentWindowsInCurrentWorkspace() -> [DesktopWindow] {
        let candidates = windowsInCurrentWorkspace()
        func rank(_ window: DesktopWindow) -> Int {
            focusHistory.firstIndex(of: window.id) ?? Int.max
        }
        return candidates.sorted { lhs, rhs in
            if lhs.isMinimized != rhs.isMinimized { return !lhs.isMinimized }
            return rank(lhs) < rank(rhs)
        }
    }

    /// The frame the window is drawn at: tiled, floating, and lifted above the keyboard
    /// when it is the focused window.
    func displayFrame(for window: DesktopWindow) -> CGRect {
        let frame = tiledOrFloatingFrame(for: window)
        guard keyboard.lifts(window.id), window.id == focusedWindowID else { return frame }
        return WindowGeometry.avoidingKeyboard(frame, availableHeight: desktopSize.height - keyboardOverlap,
                                               minimumHeight: Self.minimumSize.height)
    }

    private func tiledOrFloatingFrame(for window: DesktopWindow) -> CGRect {
        if window.isMaximized { return CGRect(origin: .zero, size: desktopSize) }
        if let tile = tileFrames[window.id] {
            return tile.offsetBy(dx: window.tileDragOffset.width, dy: window.tileDragOffset.height)
        }
        if let snap = window.snap { return WindowGeometry.frame(for: snap, in: desktopSize) }
        return window.frame
    }

    // MARK: - Lifecycle

    /// Creates a window without showing it, so its content can be built with a live handle first.
    /// A window reopened by session restore takes its saved placement.
    func makeWindow(appID: String, symbol: String, title: String, preferredSize: CGSize,
                    arguments: [String: String] = [:]) -> DesktopWindow {
        topZIndex += 1
        if var queue = pendingPlacements[appID], !queue.isEmpty {
            let placement = queue.removeFirst()
            pendingPlacements[appID] = queue.isEmpty ? nil : queue
            let window = DesktopWindow(appID: appID, symbol: symbol, title: title, arguments: arguments,
                                       frame: clamped(placement.frame), zIndex: topZIndex,
                                       workspace: min(max(placement.workspace, 0), workspaceCount - 1))
            window.snap = placement.snap
            window.isMaximized = placement.isMaximized
            window.isMinimized = placement.isMinimized
            window.isAlwaysOnTop = placement.isAlwaysOnTop
            window.isFloating = placement.isFloating ?? false
            return window
        }
        let size = WindowGeometry.initialSize(preferred: preferredSize, in: desktopSize, limits: Self.limits)
        let occupied = windows
            .filter { isVisible($0) && !$0.isTiled }
            .sorted { $0.zIndex < $1.zIndex }
            .map(\.frame)
        let frame = desktopSize.width > 0
            ? WindowGeometry.placement(for: size, avoiding: occupied, in: desktopSize, limits: Self.limits)
            : CGRect(origin: .zero, size: size)
        return DesktopWindow(appID: appID, symbol: symbol, title: title, arguments: arguments,
                             frame: frame, zIndex: topZIndex, workspace: currentWorkspace)
    }

    func present(_ window: DesktopWindow) {
        // Last chance to picture the current window while it is still on top.
        if let focused = focusedWindow { willChangeFocus?(focused) }
        withAnimation(DesktopMotion.standard) {
            windows.append(window)
            tileOrder.append(window.id)
            retile(window.workspace)
            if window.workspace == currentWorkspace && !window.isMinimized {
                setFocus(window.id)
            }
        }
        layoutDidChange()
    }

    func close(_ id: UUID) {
        withAnimation(DesktopMotion.quick) {
            let workspace = window(withID: id)?.workspace
            windows.removeAll { $0.id == id }
            tileOrder.removeAll { $0 == id }
            tileFrames[id] = nil
            if let workspace { retile(workspace) }
            focusHistory.removeAll { $0 == id }
            taskbarTargets[id] = nil
            if snapPreview?.windowID == id { snapPreview = nil }
            if focusedWindowID == id { focusNextWindow(after: id) }
        }
        layoutDidChange()
    }

    /// What the user's close button and shortcut do.
    func requestClose(_ id: UUID) {
        if let handler = window(withID: id)?.onCloseRequest {
            handler()
        } else {
            close(id)
        }
    }

    func focus(_ id: UUID) {
        guard let window = window(withID: id) else { return }
        if window.workspace != currentWorkspace {
            switchToWorkspace(window.workspace)
        }
        if window.isMinimized {
            withAnimation(DesktopMotion.standard) {
                window.isMinimized = false
                retile(window.workspace)
            }
            layoutDidChange()
        }
        raise(window)
        setFocus(id)
    }

    /// A click on the empty desktop: no window keeps keyboard focus, the desktop takes it.
    func clearFocus() {
        guard let focused = focusedWindow else { return }
        willChangeFocus?(focused)
        focusedWindowID = nil
    }

    func minimize(_ id: UUID) {
        guard let window = window(withID: id), !window.isMinimized else { return }
        withAnimation(DesktopMotion.standard) {
            window.isMinimized = true
            retile(window.workspace)
            if focusedWindowID == id { focusNextWindow(after: id) }
        }
        layoutDidChange()
    }

    func toggleMaximize(_ id: UUID) {
        guard let window = window(withID: id) else { return }
        focus(id)
        // A snapped window maximizes, like a floating one; only a maximized one restores.
        withAnimation(DesktopMotion.tile) {
            if window.isMaximized {
                window.isMaximized = false
            } else {
                window.snap = nil
                window.isMaximized = true
            }
        }
        layoutDidChange()
    }

    /// Tiles the window; snapping to the zone it already occupies restores it instead.
    func snap(_ id: UUID, to zone: SnapZone) {
        guard let window = window(withID: id) else { return }
        focus(id)
        withAnimation(DesktopMotion.tile) {
            // Snapping says where the user wants this window, so it leaves the tiling layout.
            if isTiledByLayout(window) && zone != .maximize {
                window.isFloating = true
                retile(window.workspace)
            }
            if zone == .maximize {
                window.snap = nil
                window.isMaximized.toggle()
            } else if window.snap == zone && !window.isMaximized {
                window.snap = nil
            } else {
                window.isMaximized = false
                window.snap = zone
            }
        }
        layoutDidChange()
    }

    /// Un-tiles a tiled window; a floating window is minimized, like Windows' Win+Down.
    func restoreOrMinimize(_ id: UUID) {
        guard let window = window(withID: id) else { return }
        if window.isTiled {
            withAnimation(DesktopMotion.tile) {
                window.isMaximized = false
                window.snap = nil
            }
            layoutDidChange()
        } else {
            minimize(id)
        }
    }

    func center(_ id: UUID) {
        guard let window = window(withID: id) else { return }
        focus(id)
        withAnimation(DesktopMotion.tile) {
            window.isMaximized = false
            window.snap = nil
            window.frame = clamped(WindowGeometry.centered(window.frame, in: desktopSize))
        }
        layoutDidChange()
    }

    func toggleAlwaysOnTop(_ id: UUID) {
        guard let window = window(withID: id) else { return }
        window.isAlwaysOnTop.toggle()
        raise(window)
        layoutDidChange()
    }

    /// Taskbar semantics: clicking the focused window hides it, anything else brings it forward.
    func activateFromTaskbar(_ id: UUID) {
        guard let window = window(withID: id) else { return }
        if focusedWindowID == id && !window.isMinimized {
            minimize(id)
        } else {
            focus(id)
        }
    }

    // MARK: - Workspaces

    func switchToWorkspace(_ index: Int) {
        guard (0..<workspaceCount).contains(index), index != currentWorkspace else { return }
        if let focused = focusedWindow { willChangeFocus?(focused) }
        snapPreview = nil
        currentWorkspace = index
        focusedWindowID = recentWindowsInCurrentWorkspace().first { !$0.isMinimized }?.id
        layoutDidChange()
    }

    func switchWorkspace(by offset: Int) {
        let count = workspaceCount
        switchToWorkspace(((currentWorkspace + offset) % count + count) % count)
    }

    func move(_ id: UUID, toWorkspace index: Int) {
        guard let window = window(withID: id), (0..<workspaceCount).contains(index),
              window.workspace != index else { return }
        withAnimation(DesktopMotion.quick) {
            let previous = window.workspace
            window.workspace = index
            retile(previous)
            retile(index)
            if focusedWindowID == id && index != currentWorkspace { focusNextWindow(after: id) }
        }
        layoutDidChange()
    }

    func title(ofWorkspace index: Int) -> String {
        let name = workspaceNames.indices.contains(index) ? workspaceNames[index] : ""
        return name.isEmpty ? "Workspace \(index + 1)" : name
    }

    /// Adds an empty workspace at the end. Returns its index, or nil at the maximum.
    @discardableResult
    func addWorkspace() -> Int? {
        guard workspaceCount < Self.maximumWorkspaces else { return nil }
        workspaceNames.append("")
        tiling.append(TilingState())
        onTilingChange?(tiling)
        layoutDidChange()
        return workspaceCount - 1
    }

    /// Deletes a workspace; its windows move to the neighbouring one (the previous, or the
    /// next for the first). The last workspace cannot be deleted.
    func removeWorkspace(_ index: Int) {
        guard workspaceCount > 1, workspaceNames.indices.contains(index) else { return }
        let neighbour = index > 0 ? index - 1 : 0
        var mapping: [Int: Int] = [:]
        for old in 0..<workspaceCount where old != index { mapping[old] = old < index ? old : old - 1 }
        withAnimation(DesktopMotion.quick) {
            for window in windows {
                window.workspace = window.workspace == index ? neighbour : (mapping[window.workspace] ?? neighbour)
            }
            workspaceNames.remove(at: index)
            tiling.remove(at: index)
            currentWorkspace = currentWorkspace == index ? neighbour : (mapping[currentWorkspace] ?? 0)
            retileAll()
        }
        if let focused = focusedWindow, focused.workspace != currentWorkspace { focusedWindowID = nil }
        if focusedWindowID == nil { focusedWindowID = recentWindowsInCurrentWorkspace().first { !$0.isMinimized }?.id }
        onWorkspacesRemapped?(mapping)
        onTilingChange?(tiling)
        layoutDidChange()
    }

    /// Moves workspace `source` to position `destination`, taking its windows, name and
    /// tiling along; ⌃⌥1…9 follow the new order.
    func moveWorkspace(from source: Int, to destination: Int) {
        guard workspaceNames.indices.contains(source), workspaceNames.indices.contains(destination),
              source != destination else { return }
        var order = Array(0..<workspaceCount)
        order.insert(order.remove(at: source), at: destination)
        var mapping: [Int: Int] = [:]
        for (new, old) in order.enumerated() { mapping[old] = new }
        withAnimation(DesktopMotion.quick) {
            for window in windows { window.workspace = mapping[window.workspace] ?? window.workspace }
            workspaceNames = order.map { workspaceNames[$0] }
            tiling = order.map { tiling[$0] }
            currentWorkspace = mapping[currentWorkspace] ?? currentWorkspace
        }
        onWorkspacesRemapped?(mapping)
        onTilingChange?(tiling)
        layoutDidChange()
    }

    func renameWorkspace(_ index: Int, to name: String) {
        guard workspaceNames.indices.contains(index) else { return }
        workspaceNames[index] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        layoutDidChange()
    }

    /// Session restore: the saved workspaces, before any window is placed.
    func restoreWorkspaces(names: [String]) {
        let count = min(max(names.count, 1), Self.maximumWorkspaces)
        workspaceNames = Array(names.prefix(count))
        if tiling.count < count {
            tiling += Array(repeating: TilingState(), count: count - tiling.count)
        } else {
            tiling = Array(tiling.prefix(count))
        }
        currentWorkspace = min(currentWorkspace, count - 1)
    }

    func hasWindows(inWorkspace index: Int) -> Bool {
        windows.contains { $0.workspace == index }
    }

    // MARK: - Interactive move and resize

    func updateDesktopSize(_ size: CGSize) {
        guard size != desktopSize, size.width > 0, size.height > 0 else { return }
        desktopSize = size
        for window in windows {
            window.frame = WindowGeometry.keptOnScreen(clamped(window.frame), in: size)
        }
        retileAll()
    }

    /// The keyboard's end frame in desktop coordinates (nil when it went away).
    func updateKeyboard(_ frame: CGRect?, hardwareKeyboard: Bool) {
        var next = keyboard
        next.keyboardChanged(to: frame.map { $0.integral }, desktop: CGRect(origin: .zero, size: desktopSize),
                             hardwareKeyboard: hardwareKeyboard, focusedWindow: focusedWindowID)
        guard next != keyboard else { return }
        withAnimation(DesktopMotion.standard) { keyboard = next }
    }

    /// A docked keyboard `overlap` points tall (0: none).
    func updateKeyboardOverlap(_ overlap: CGFloat) {
        guard overlap > 0 else { return resetKeyboard() }
        updateKeyboard(CGRect(x: 0, y: desktopSize.height - overlap, width: desktopSize.width, height: overlap),
                       hardwareKeyboard: false)
    }

    /// Keyboard hidden, app in the background: every window back to its own frame.
    func resetKeyboard() {
        guard keyboard != KeyboardAvoidance() else { return }
        withAnimation(DesktopMotion.standard) { keyboard.reset() }
    }

    /// Returns the frame the drag should be measured from. A maximized or snapped window
    /// is restored to its floating size under the finger, the way desktop window managers do.
    func beginMove(_ id: UUID, pointer: CGPoint) -> CGRect? {
        guard let window = window(withID: id) else { return nil }
        focus(id)
        window.isInteracting = true
        if let tile = tileFrames[id], !window.isMaximized {
            return tile
        }
        let current = displayFrame(for: window)
        if window.isTiled {
            let size = window.frame.size
            let grabRatio = current.width > 0 ? (pointer.x - current.minX) / current.width : 0.5
            let restored = CGRect(x: pointer.x - size.width * grabRatio, y: current.minY,
                                  width: size.width, height: size.height)
            window.isMaximized = false
            window.snap = nil
            window.frame = clamped(restored)
        } else if current != window.frame {
            window.frame = clamped(current)
        }
        return window.frame
    }

    func updateMove(_ id: UUID, from origin: CGRect, translation: CGSize, pointer: CGPoint) {
        guard let window = window(withID: id) else { return }
        if isTiledByLayout(window) && !window.isMaximized {
            window.tileDragOffset = translation
            let preview = tiledWindow(at: pointer, excluding: id).flatMap { target in
                tileFrames[target.id].map { SnapPreview(windowID: id, frame: $0) }
            }
            if preview != snapPreview {
                withAnimation(DesktopMotion.quick) { snapPreview = preview }
            }
            return
        }
        window.frame = clamped(origin.offsetBy(dx: translation.width, dy: translation.height))

        let preview = WindowGeometry.snapZone(at: pointer, in: desktopSize)
            .map { SnapPreview(windowID: id, frame: WindowGeometry.frame(for: $0, in: desktopSize)) }
        if preview != snapPreview {
            withAnimation(DesktopMotion.quick) { snapPreview = preview }
        }
    }

    func endMove(_ id: UUID, from origin: CGRect, pointer: CGPoint) {
        withAnimation(DesktopMotion.quick) { snapPreview = nil }
        guard let window = window(withID: id) else { return }
        window.isInteracting = false
        if isTiledByLayout(window) && !window.isMaximized {
            withAnimation(DesktopMotion.tile) {
                if let target = tiledWindow(at: pointer, excluding: id) {
                    swapTiles(id, target.id)
                }
                window.tileDragOffset = .zero
            }
            layoutDidChange()
            return
        }
        if let zone = WindowGeometry.snapZone(at: pointer, in: desktopSize) {
            withAnimation(DesktopMotion.tile) {
                window.frame = origin
                if zone == .maximize {
                    window.isMaximized = true
                } else {
                    window.snap = zone
                }
            }
        }
        layoutDidChange()
    }

    func cancelMove(_ id: UUID) {
        withAnimation(DesktopMotion.quick) { snapPreview = nil }
        guard let window = window(withID: id) else { return }
        window.isInteracting = false
        withAnimation(DesktopMotion.tile) { window.tileDragOffset = .zero }
    }

    /// A tiled window becomes free-floating at its current size before resizing.
    func beginResize(_ id: UUID) -> CGRect? {
        guard let window = window(withID: id), !window.isMaximized else { return nil }
        focus(id)
        window.isInteracting = true
        if let tile = tileFrames[id] { return tile }
        if window.snap != nil {
            window.frame = displayFrame(for: window)
            window.snap = nil
        }
        return window.frame
    }

    func updateResize(_ id: UUID, from origin: CGRect, edge: ResizeEdge, translation: CGSize) {
        guard let window = window(withID: id) else { return }
        if isTiledByLayout(window) {
            resizeSplit(of: window, from: origin, edge: edge, translation: translation)
            return
        }
        window.frame = WindowGeometry.resized(origin, edge: edge, translation: translation,
                                              in: desktopSize, limits: Self.limits)
    }

    func endResize(_ id: UUID) {
        window(withID: id)?.isInteracting = false
        onTilingChange?(tiling)
        layoutDidChange()
    }

    // MARK: - Tiling

    func isTiling(workspace index: Int) -> Bool {
        tiling.indices.contains(index) && tiling[index].isEnabled
    }

    func setTiling(_ enabled: Bool, workspace index: Int? = nil) {
        let index = index ?? currentWorkspace
        guard tiling.indices.contains(index), tiling[index].isEnabled != enabled else { return }
        withAnimation(DesktopMotion.tile) {
            tiling[index].isEnabled = enabled
            for window in windows(inWorkspace: index) {
                window.isMaximized = false
                window.snap = nil
                if !enabled { window.isFloating = false }
            }
            retile(index)
        }
        onTilingChange?(tiling)
        layoutDidChange()
    }

    func setTilingLayout(_ layout: TilingLayout, workspace index: Int? = nil) {
        let index = index ?? currentWorkspace
        guard tiling.indices.contains(index) else { return }
        withAnimation(DesktopMotion.tile) {
            tiling[index].layout = layout
            tiling[index].isEnabled = true
            retile(index)
        }
        onTilingChange?(tiling)
    }

    func cycleTilingLayout() {
        let all = TilingLayout.allCases
        let current = tiling[currentWorkspace].layout
        let next = all[((all.firstIndex(of: current) ?? 0) + 1) % all.count]
        setTilingLayout(next)
    }

    func restoreTiling(_ states: [TilingState]) {
        for (index, state) in states.enumerated() where tiling.indices.contains(index) {
            tiling[index] = state
        }
        retileAll()
    }

    /// Takes the window out of (or back into) its workspace's tiling layout.
    func toggleFloating(_ id: UUID) {
        guard let window = window(withID: id) else { return }
        withAnimation(DesktopMotion.tile) {
            window.isFloating.toggle()
            window.snap = nil
            window.isMaximized = false
            raise(window)
            retile(window.workspace)
        }
        layoutDidChange()
    }

    /// Ctrl-Option-H/J/K/L and the arrows in a tiling workspace: focus the neighbouring tile.
    func focusTile(dx: Int, dy: Int) {
        guard let focused = focusedWindow, let neighbor = tileNeighbor(of: focused, dx: dx, dy: dy) else { return }
        focus(neighbor.id)
    }

    /// With Shift: swap the focused tile with its neighbour, keeping focus on the moved window.
    func moveTile(dx: Int, dy: Int) {
        guard let focused = focusedWindow, let neighbor = tileNeighbor(of: focused, dx: dx, dy: dy) else { return }
        withAnimation(DesktopMotion.tile) { swapTiles(focused.id, neighbor.id) }
        layoutDidChange()
    }

    private func tileNeighbor(of window: DesktopWindow, dx: Int, dy: Int) -> DesktopWindow? {
        guard let frame = tileFrames[window.id] else { return nil }
        let candidates = windows.filter { $0.workspace == window.workspace && tileFrames[$0.id] != nil }
        let tiles = candidates.compactMap { tileFrames[$0.id] }
        return WindowGeometry.neighbor(of: frame, in: tiles, dx: dx, dy: dy).map { candidates[$0] }
    }

    private func tiledWindow(at point: CGPoint, excluding id: UUID) -> DesktopWindow? {
        windows.first { $0.id != id && $0.workspace == currentWorkspace && tileFrames[$0.id]?.contains(point) == true }
    }

    private func swapTiles(_ a: UUID, _ b: UUID) {
        guard let i = tileOrder.firstIndex(of: a), let j = tileOrder.firstIndex(of: b),
              let workspace = window(withID: a)?.workspace else { return }
        tileOrder.swapAt(i, j)
        retile(workspace)
    }

    /// Dragging the edge between master and stack changes the master ratio.
    private func resizeSplit(of window: DesktopWindow, from origin: CGRect, edge: ResizeEdge, translation: CGSize) {
        let index = window.workspace
        let members = tiledMembers(of: index)
        guard tiling[index].layout == .masterStack, members.count > 1,
              let position = members.firstIndex(where: { $0.id == window.id }) else { return }
        let isMaster = position == 0
        guard (isMaster && edge.movesMaxX) || (!isMaster && edge.movesMinX) else { return }
        let split = isMaster ? origin.maxX + translation.width : origin.minX + translation.width - innerGap
        tiling[index].masterRatio = WindowGeometry.masterRatio(forSplitAt: split, in: desktopSize, gap: innerGap,
                                                               outerGap: outerGap)
        retile(index)
    }

    private func tiledMembers(of workspace: Int) -> [DesktopWindow] {
        tileOrder.compactMap(window(withID:)).filter {
            $0.workspace == workspace && !$0.isFloating && !$0.isMinimized
        }
    }

    private func retile(_ workspace: Int) {
        guard tiling.indices.contains(workspace) else { return }
        for window in windows where window.workspace == workspace { tileFrames[window.id] = nil }
        let state = tiling[workspace]
        guard state.isEnabled, desktopSize.width > 0 else { return }
        let members = tiledMembers(of: workspace)
        let frames = WindowGeometry.tileFrames(count: members.count, layout: state.layout, in: desktopSize,
                                               gap: innerGap, outerGap: outerGap, masterRatio: state.masterRatio)
        for (window, frame) in zip(members, frames) {
            tileFrames[window.id] = frame
        }
    }

    private func retileAll() {
        for index in 0..<workspaceCount { retile(index) }
    }

    // MARK: - Session restore

    func enqueuePlacement(_ placement: WindowPlacement, forAppID appID: String) {
        pendingPlacements[appID, default: []].append(placement)
    }

    func placement(of window: DesktopWindow) -> WindowPlacement {
        WindowPlacement(frame: window.frame, workspace: window.workspace, snap: window.snap,
                        isMaximized: window.isMaximized, isMinimized: window.isMinimized,
                        isAlwaysOnTop: window.isAlwaysOnTop, isFloating: window.isFloating ? true : nil)
    }

    func restoreWorkspace(_ index: Int) {
        guard (0..<workspaceCount).contains(index) else { return }
        currentWorkspace = index
        focusedWindowID = visibleStack().first?.id
    }

    // MARK: - Private

    private func raise(_ window: DesktopWindow) {
        guard window.zIndex != topZIndex else { return }
        topZIndex += 1
        window.zIndex = topZIndex
    }

    private func setFocus(_ id: UUID?) {
        guard id != focusedWindowID else { return }
        if let focused = focusedWindow { willChangeFocus?(focused) }
        focusedWindowID = id
        if let id {
            focusHistory.removeAll { $0 == id }
            focusHistory.insert(id, at: 0)
        }
    }

    /// Focus moves to the window that was focused before, the way users expect after
    /// closing or minimizing, rather than to whatever happens to be on top.
    private func focusNextWindow(after id: UUID) {
        let next = recentWindowsInCurrentWorkspace().first { $0.id != id && !$0.isMinimized }
        focusedWindowID = next?.id
        if let next {
            raise(next)
            focusHistory.removeAll { $0 == next.id }
            focusHistory.insert(next.id, at: 0)
        }
    }

    private func clamped(_ frame: CGRect) -> CGRect {
        WindowGeometry.clamped(frame, in: desktopSize, limits: Self.limits)
    }

    private func layoutDidChange() {
        onLayoutChange?()
    }
}

/// Shared animation curves. Reduce Motion swaps them for short cross-fades in the views.
enum DesktopMotion {
    static let standard = Animation.snappy(duration: 0.22)
    static let quick = Animation.snappy(duration: 0.18)
    static let tile = Animation.snappy(duration: 0.25)
}

/// The handle an app holds. Weak so an app view retaining its context cannot keep a closed window alive.
@MainActor
final class DesktopWindowHandle: WindowHandle {
    let id: UUID
    private weak var window: DesktopWindow?
    private weak var manager: WindowManager?

    init(window: DesktopWindow, manager: WindowManager) {
        self.id = window.id
        self.window = window
        self.manager = manager
    }

    func setTitle(_ title: String) {
        guard let window, window.title != title else { return }
        window.title = title
    }

    func close() {
        manager?.close(id)
    }
}
