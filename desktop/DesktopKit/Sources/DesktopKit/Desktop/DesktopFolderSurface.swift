import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// A desktop launcher icon being moved to another cell; never leaves the desktop.
    static let desktopLauncher = UTType(exportedAs: "com.valentinneagu.ish.desktop-launcher", conformingTo: .data)
}

/// One icon on the desktop.
enum DesktopItem: Identifiable, Equatable {
    case app(id: String, name: String, symbol: String)
    case trash
    case file(FileEntry)

    var id: String {
        switch self {
        case .app(let id, _, _): return "app:" + id
        case .trash: return "special:trash"
        case .file(let entry): return "file:" + entry.name
        }
    }

    var name: String {
        switch self {
        case .app(_, let name, _): return name
        case .trash: return "Trash"
        case .file(let entry): return entry.name
        }
    }

    var entry: FileEntry? {
        if case .file(let entry) = self { return entry }
        return nil
    }
}

/// The desktop as a real folder: `~/Desktop` in the guest shows as icons next to the app
/// launchers, accepts drops from anywhere, and icon positions persist.
@MainActor @Observable
final class DesktopFolderModel {
    static let showIconsKey = "desktop.icons.visible"

    @ObservationIgnored private weak var controller: DesktopController?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored let operations: FileOperations
    @ObservationIgnored let trash: FileTrash
    @ObservationIgnored let transfer: GuestTransferService
    let desktopPath: String

    private(set) var entries: [FileEntry] = []
    var layout = DesktopIconLayout.load()
    var selection: Set<String> = []
    var dropTarget: String?
    private(set) var size: CGSize = .zero
    var errorMessage: String?
    /// Icons being dragged directly (not a system drag session) and how far.
    var dragKeys: [String] = []
    var dragTranslation: CGSize = .zero
    /// The rubber band's rectangle while selecting with a drag on the empty desktop.
    var rubberBand: CGRect?
    @ObservationIgnored private var rubberBandBase: Set<String> = []
    /// Style and screen size the layout belongs to; each keeps its own arrangement.
    @ObservationIgnored private var layoutContext: String?
    @ObservationIgnored var onRenameRequest: ((FileEntry) -> Void)?

    private static let pollInterval: Duration = .seconds(10)

    init(controller: DesktopController) {
        if UserDefaults.standard.bool(forKey: DesktopIconLayout.resetArgument) {
            DesktopIconLayout.reset()
            controller.desktopAppIDs = nil
        }
        self.controller = controller
        let host = controller.host
        operations = FileOperations(host: host)
        transfer = GuestTransferService(host: host)
        let home = AppPath.normalize(host.homeDirectory)
        trash = FileTrash(host: host, homeDirectory: home)
        desktopPath = AppPath.join(home, "Desktop")
    }

    func start() {
        guard pollTask == nil, let host = controller?.host else { return }
        OpenWithCatalog.shared.loadIfNeeded(host: host)
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            _ = await host.run("mkdir -p -- \(AppPath.join(host.homeDirectory, "Desktop").shellQuoted)", cwd: nil, stdin: nil)
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func refresh() async {
        guard let host = controller?.host, let list = try? await host.listDirectory(desktopPath) else { return }
        let visible = list.filter { !$0.name.hasPrefix(".") }
        if visible != entries {
            entries = visible
            if let key = layout.keepsArranged { arrange(by: key) }
        }
    }

    // MARK: Layout

    /// Switches to the layout saved for this style and size (rotation, Stage Manager, a style
    /// change); icons that no longer fit flow back onto the grid.
    func updateContext(style: DesktopStyle, size: CGSize, iconSize: DesktopIconSize) {
        guard size.width > 0, size.height > 0 else { return }
        self.size = size
        let context = "\(style.rawValue).\(Int(size.width))x\(Int(size.height))"
        if context != layoutContext {
            layoutContext = context
            layout = DesktopIconLayout.load(context: context)
        }
        layout.iconSize = iconSize
    }

    func saveLayout() {
        layout.save(context: layoutContext)
    }

    var positions: [String: CGPoint] {
        layout.positions(items.map(\.id), in: size)
    }

    /// Where the dragged icons would land, for the snap preview.
    var dragPreview: [String: CGPoint] {
        guard !dragKeys.isEmpty else { return [:] }
        var preview = layout
        preview.drag(dragKeys, by: dragTranslation, allKeys: items.map(\.id), in: size)
        let all = preview.positions(items.map(\.id), in: size)
        return all.filter { dragKeys.contains($0.key) }
    }

    /// A direct drag (touch or pointer) moved icons by `translation`.
    func commitDrag() {
        let keys = dragKeys
        let translation = dragTranslation
        dragKeys = []
        dragTranslation = .zero
        guard !keys.isEmpty, hypot(translation.width, translation.height) > 2 else { return }
        withAnimation(DesktopMotion.standard) {
            layout.drag(keys, by: translation, allKeys: items.map(\.id), in: size)
        }
        saveLayout()
    }

    /// Ends a direct drag. Over another app's window the selected files go to that window
    /// (as a system drag would deliver them); over the Trash or a folder icon they move
    /// there; anywhere else on the desktop the icons move.
    func endDrag(atLocal point: CGPoint, global: CGPoint) {
        defer { dropTarget = nil }
        let keys = dragKeys
        if let controller, let desktopPoint = DragDropCenter.shared.desktopPoint(fromWindowPoint: global) {
            let manager = controller.windowManager
            if manager.visibleStack().contains(where: { manager.displayFrame(for: $0).contains(desktopPoint) }) {
                cancelDrag()
                let files = items.filter { keys.contains($0.id) }.compactMap(\.entry)
                guard !files.isEmpty else { return }
                guard let handler = DragDropCenter.shared.nativeHandler(atWindowPoint: global) else {
                    controller.notify("Touch and hold an icon briefly to drag it into a Linux app.")
                    return
                }
                handler(files.map { .guestFile(path: $0.path, isDirectory: $0.isDirectory) }, DropOperation.forGuestDrag())
                return
            }
        }
        if let target = dropDirectory(at: point, excluding: keys) {
            cancelDrag()
            let files = items.filter { keys.contains($0.id) }.compactMap(\.entry)
            if target == trash.filesDirectory {
                moveToTrash(files)
            } else if !files.isEmpty {
                let paths = files.map(\.path)
                let operation = DropOperation.forGuestDrag()
                run { [operations] in try await operations.transfer(paths, into: target, operation: operation) }
            }
            return
        }
        commitDrag()
    }

    func cancelDrag() {
        dragKeys = []
        dragTranslation = .zero
    }

    /// The Trash or folder icon under `point`, as a drop directory.
    func dropDirectory(at point: CGPoint, excluding keys: [String]) -> String? {
        let positions = positions
        for item in items where !keys.contains(item.id) {
            guard let origin = positions[item.id],
                  CGRect(origin: origin, size: layout.cellSize).insetBy(dx: 8, dy: 8).contains(point) else { continue }
            switch item {
            case .trash: return trash.filesDirectory
            case .file(let entry) where entry.isDirectory: return entry.path
            default: return nil
            }
        }
        return nil
    }

    func setSnapsToGrid(_ snaps: Bool) {
        let keys = items.map(\.id)
        withAnimation(DesktopMotion.standard) {
            if snaps {
                layout.alignToGrid(keys, in: size)
            } else {
                layout.free = layout.positions(keys, in: size)
            }
            layout.snapsToGrid = snaps
        }
        saveLayout()
    }

    func alignToGrid() {
        withAnimation(DesktopMotion.standard) { layout.alignToGrid(items.map(\.id), in: size) }
        saveLayout()
    }

    func setKeepsArranged(_ key: DesktopArrangeKey?) {
        layout.keepsArranged = key
        if let key { arrange(by: key) } else { saveLayout() }
    }

    // MARK: Rubber band and keyboard

    func beginRubberBand(at point: CGPoint, additive: Bool) {
        rubberBandBase = additive ? selection : []
        rubberBand = CGRect(origin: point, size: .zero)
        if !additive { selection = [] }
    }

    func updateRubberBand(from start: CGPoint, to point: CGPoint) {
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        rubberBand = rect
        let hits = positions.filter { CGRect(origin: $0.value, size: layout.cellSize).insetBy(dx: 10, dy: 8).intersects(rect) }
        selection = rubberBandBase.union(hits.keys)
    }

    func endRubberBand() {
        rubberBand = nil
    }

    func handle(_ key: DesktopIconKey) -> Bool {
        let positions = positions
        switch key {
        case .selectAll:
            selection = Set(items.map(\.id))
        case .move(let dx, let dy):
            guard let current = selection.first.flatMap({ positions[$0] }) ?? positions.values.min(by: { ($0.x, $0.y) < ($1.x, $1.y) })
            else { return false }
            let candidates = positions.filter { key, point in
                let deltaX = point.x - current.x, deltaY = point.y - current.y
                return (dx != 0 && deltaX * CGFloat(dx) > 4) || (dy != 0 && deltaY * CGFloat(dy) > 4)
            }
            let next = candidates.min { lhs, rhs in
                func cost(_ point: CGPoint) -> CGFloat {
                    let along = dx != 0 ? abs(point.x - current.x) : abs(point.y - current.y)
                    let across = dx != 0 ? abs(point.y - current.y) : abs(point.x - current.x)
                    return along + across * 3
                }
                return cost(lhs.value) < cost(rhs.value)
            }
            if let next { selection = [next.key] } else if selection.isEmpty, let first = positions.first { selection = [first.key] }
        case .open:
            for item in items where selection.contains(item.id) { open(item) }
        case .trash:
            moveToTrash(selectedEntries)
        case .rename:
            guard let entry = selectedEntries.first, selectedEntries.count == 1 else { return false }
            onRenameRequest?(entry)
        }
        return true
    }

    func refreshSoon() {
        Task { await refresh() }
    }

    var items: [DesktopItem] {
        guard let controller else { return [] }
        let apps = controller.desktopApps.map { DesktopItem.app(id: $0.id, name: $0.name, symbol: $0.symbol) }
        return apps + [.trash] + entries.map(DesktopItem.file)
    }

    var cells: [String: DesktopIconLayout.Cell] {
        layout.resolved(items.map(\.id), in: size)
    }

    // MARK: Selection and opening

    func click(_ item: DesktopItem) {
        if KeyboardModifiers.isCommandDown || KeyboardModifiers.isShiftDown {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = [item.id]
        }
    }

    var selectedEntries: [FileEntry] {
        items.filter { selection.contains($0.id) }.compactMap(\.entry)
    }

    func targets(for entry: FileEntry) -> [FileEntry] {
        selection.contains("file:" + entry.name) ? selectedEntries : [entry]
    }

    func open(_ item: DesktopItem) {
        guard let controller else { return }
        switch item {
        case .app(let id, _, _):
            controller.open(appID: id, arguments: [:])
        case .trash:
            controller.open(appID: AppID.files, arguments: [AppArgument.path: trash.filesDirectory])
        case .file(let entry):
            if entry.isDirectory {
                controller.open(appID: AppID.files, arguments: [AppArgument.path: entry.path])
                return
            }
            switch OpenWithCatalog.shared.defaultOpen(for: entry.name) {
            case .editor: controller.open(appID: AppID.editor, arguments: [AppArgument.path: entry.path])
            case .linux(let app): openWith(entry, app: app)
            case .quickLook: quickLook([entry])
            }
        }
    }

    func openWith(_ entry: FileEntry, app: OpenWithCatalog.Application) {
        controller?.open(appID: LinuxAppID.prefix + OpenWithCatalog.command(exec: app.exec, path: entry.path), arguments: [:])
    }

    func openInEditor(_ entry: FileEntry) {
        controller?.open(appID: AppID.editor, arguments: [AppArgument.path: entry.path])
    }

    func openTerminal(at directory: String) {
        controller?.open(appID: LinuxAppID.preferredTerminal, arguments: [AppArgument.cwd: directory])
    }

    func quickLook(_ items: [FileEntry]) {
        if QuickLookPresenter.shared.isPresenting {
            QuickLookPresenter.shared.dismiss()
            return
        }
        let files = items.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for file in files {
                if let url = try? await QuickLookPresenter.shared.exportedURL(for: file, transfer: transfer) { urls.append(url) }
            }
            QuickLookPresenter.shared.preview(urls)
        }
    }

    /// Keys while the desktop itself has focus (no window focused) and icons are selected.
    func handle(_ key: FileKey) {
        let selected = selectedEntries
        switch key {
        case .quickLook: quickLook(selected)
        case .open: items.filter { selection.contains($0.id) }.forEach(open)
        case .trash, .trashCommand: moveToTrash(selected)
        case .copy: FileClipboard.shared.copy(selected.map(\.path))
        case .cut: FileClipboard.shared.cut(selected.map(\.path))
        case .paste: paste()
        case .selectAll: selection = Set(items.map(\.id))
        case .escape: selection = []
        default: break
        }
    }

    func share(_ items: [FileEntry]) {
        Task {
            var urls: [URL] = []
            for item in items {
                if let url = try? await transfer.exportItem(item.path, isDirectory: item.isDirectory) { urls.append(url) }
            }
            if !urls.isEmpty { HostPresenter.share(urls) }
        }
    }

    // MARK: File operations

    func run(_ work: @escaping @MainActor () async throws -> [String], placeAt cell: DesktopIconLayout.Cell? = nil) {
        Task {
            do {
                let results = try await work()
                await refresh()
                let keys = results.filter { AppPath.parent(of: $0) == desktopPath }.map { "file:" + AppPath.lastComponent($0) }
                if let cell, !keys.isEmpty {
                    layout.move(keys, to: cell, allKeys: items.map(\.id), in: size)
                    saveLayout()
                }
                if !keys.isEmpty { selection = Set(keys) }
            } catch {
                controller?.notify((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                await refresh()
            }
        }
    }

    func create(folder: Bool, named rawName: String) {
        let name = rawName.trimmedWhitespace
        guard AppPath.isValidName(name), let host = controller?.host else { return }
        let target = AppPath.join(desktopPath, name)
        run {
            let quoted = target.shellQuoted
            let result = await host.run("""
                if [ -e \(quoted) ]; then echo 'An item with that name already exists.' >&2; exit 1; fi
                \(folder ? "mkdir -p --" : "touch --") \(quoted)
                """, cwd: nil, stdin: nil)
            guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
            return [target]
        }
    }

    func rename(_ entry: FileEntry, to rawName: String) {
        let name = rawName.trimmedWhitespace
        guard name != entry.name, AppPath.isValidName(name), let host = controller?.host else { return }
        let target = AppPath.join(desktopPath, name)
        let oldKey = "file:" + entry.name
        run { [self] in
            let result = await host.run("""
                if [ -e \(target.shellQuoted) ]; then echo 'An item with that name already exists.' >&2; exit 1; fi
                mv -- \(entry.path.shellQuoted) \(target.shellQuoted)
                """, cwd: nil, stdin: nil)
            guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
            // The icon stays where it was under its new name.
            if let cell = layout.cells.removeValue(forKey: oldKey) {
                layout.cells["file:" + name] = cell
            }
            if let point = layout.free.removeValue(forKey: oldKey) {
                layout.free["file:" + name] = point
            }
            saveLayout()
            return [target]
        }
    }

    func paste() {
        let clipboard = FileClipboard.shared
        guard !clipboard.isEmpty else { return }
        let paths = clipboard.paths
        let isCut = clipboard.isCut
        run { [operations, desktopPath] in
            let results = try await operations.transfer(paths, into: desktopPath, operation: isCut ? .move : .copy)
            if isCut { clipboard.clear() }
            return results
        }
    }

    func moveToTrash(_ items: [FileEntry]) {
        guard !items.isEmpty else { return }
        run { [trash] in
            try await trash.trash(items.map(\.path))
            return []
        }
    }

    func deletePermanently(_ items: [FileEntry]) {
        run { [operations, desktopPath] in
            try await operations.deletePermanently(items.map(\.path), protecting: [desktopPath])
            return []
        }
    }

    func duplicate(_ items: [FileEntry]) {
        run { [operations] in try await operations.duplicate(items.map(\.path)) }
    }

    func compress(_ items: [FileEntry]) {
        run { [operations] in [try await operations.compress(items.map(\.path), format: .tarGz)] }
    }

    func extractHere(_ entry: FileEntry) {
        run { [operations] in [try await operations.extractHere(entry.path)] }
    }

    func arrange(by key: DesktopArrangeKey) {
        switch key {
        case .name: arrange(by: FilesSortKey.name)
        case .type: arrange(by: FilesSortKey.kind)
        case .date: arrange(by: FilesSortKey.modified)
        }
    }

    func arrange(by key: FilesSortKey) {
        let apps = items.filter { if case .file = $0 { return false } else { return true } }.map(\.id)
        let files = entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch key {
            case .name: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .size: return lhs.size > rhs.size
            case .modified: return (lhs.modified ?? .distantPast) > (rhs.modified ?? .distantPast)
            case .kind: return AppPath.pathExtension(lhs.name) < AppPath.pathExtension(rhs.name)
            }
        }.map { "file:" + $0.name }
        withAnimation(DesktopMotion.standard) { layout.arrange(apps + files, in: size) }
        saveLayout()
    }

    // MARK: Drops

    /// A drop on the desktop at `point`: icons dragged within the desktop move to that
    /// cell; guest files are moved in (copied with Option); anything else is imported.
    func drop(_ providers: [NSItemProvider], at point: CGPoint, operation: DropOperation) {
        let cell = layout.cell(at: point, in: size)
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.desktopLauncher.identifier) }) {
            Task {
                var keys: [String] = []
                for provider in providers {
                    if let key = try? await Self.loadString(provider, type: .desktopLauncher) { keys.append(key) }
                }
                moveIcons(keys, to: cell)
            }
            return
        }
        Task {
            let (payload, items) = await DragItemProviders.loadItems(from: providers)
            if let payload, payload.paths.allSatisfy({ AppPath.parent(of: $0) == desktopPath }) {
                moveIcons(payload.paths.map { "file:" + AppPath.lastComponent($0) }, to: cell)
                return
            }
            receive(items, operation: payload == nil ? .copy : operation, at: cell)
        }
    }

    func moveIcons(_ keys: [String], to cell: DesktopIconLayout.Cell) {
        guard !keys.isEmpty else { return }
        withAnimation(DesktopMotion.standard) {
            layout.move(keys, to: cell, allKeys: items.map(\.id), in: size)
        }
        saveLayout()
    }

    func receive(_ items: [DragItem], operation: DropOperation, at cell: DesktopIconLayout.Cell? = nil) {
        let guestPaths = items.compactMap(\.guestPath)
        run({ [operations, transfer, desktopPath] in
            var results: [String] = []
            if !guestPaths.isEmpty {
                results += try await operations.transfer(guestPaths, into: desktopPath, operation: operation)
            }
            for item in items {
                switch item {
                case .guestFile:
                    continue
                case .hostFile(let url):
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    results.append(try await transfer.importItem(at: url, into: desktopPath))
                case .data(let data, let name):
                    results.append(try await transfer.importData(data, named: name, into: desktopPath))
                case .text(let text):
                    results.append(try await transfer.importData(Data(text.utf8), named: "Dropped Text.txt", into: desktopPath))
                case .url(let url):
                    let link = DesktopLink(url: url)
                    results.append(try await transfer.importData(Data(link.contents.utf8), named: link.fileName, into: desktopPath))
                }
            }
            return results
        }, placeAt: cell)
    }

    func dragProvider(for item: DesktopItem) -> NSItemProvider {
        if !selection.contains(item.id) { selection = [item.id] }
        guard case .file = item else {
            let provider = NSItemProvider()
            let key = Data(item.id.utf8)
            provider.registerDataRepresentation(forTypeIdentifier: UTType.desktopLauncher.identifier, visibility: .ownProcess) { completion in
                completion(key, nil)
                return nil
            }
            return provider
        }
        let entries = items.filter { selection.contains($0.id) }.compactMap(\.entry)
        let payload = entries.map { GuestItemsPayload.Item(path: $0.path, isDirectory: $0.isDirectory) }
        return DragItemProviders.provider(for: payload, sourceWindow: nil, transfer: transfer)
    }

    private static func loadString(_ provider: NSItemProvider, type: UTType) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: String(decoding: data, as: UTF8.self)) } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}

private enum DesktopPrompt: Identifiable {
    case newFolder, newFile, rename(FileEntry)

    var id: String {
        switch self {
        case .newFolder: return "folder"
        case .newFile: return "file"
        case .rename(let entry): return "rename:" + entry.path
        }
    }

    var title: String {
        switch self {
        case .newFolder: return "New Folder"
        case .newFile: return "New File"
        case .rename(let entry): return "Rename “\(entry.name)”"
        }
    }
}

/// The desktop surface: the background (menu, pinch to the overview, drops) and the icons.
struct DesktopFolderSurface: View {
    let controller: DesktopController
    /// The shell's own desktop menu items (Open Terminal, Overview, Settings…).
    let shellItems: [DesktopMenuItem]

    @State private var model: DesktopFolderModel
    @State private var prompt: DesktopPrompt?
    @State private var promptText = ""
    @State private var pendingDeletion: [FileEntry] = []
    @State private var propertiesTarget: PropertiesTarget?
    @State private var surfaceOrigin: CGPoint = .zero
    @AppStorage(DesktopFolderModel.showIconsKey) private var showsIcons = true
    @AppStorage(DesktopIconSize.storageKey) private var iconSize = DesktopIconSize.medium
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopStyle) private var style

    init(controller: DesktopController, shellItems: [DesktopMenuItem]) {
        self.controller = controller
        self.shellItems = shellItems
        _model = State(initialValue: DesktopFolderModel(controller: controller))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                DesktopBackgroundArea(menu: backgroundMenu, onTap: clearSelection, onPinchIn: {
                    controller.setOverviewPresented(true)
                }, onBand: { phase, start, point in
                    switch phase {
                    case .began: model.beginRubberBand(at: start, additive: KeyboardModifiers.isCommandDown || KeyboardModifiers.isShiftDown)
                    case .changed: model.updateRubberBand(from: start, to: point)
                    case .ended: model.endRubberBand()
                    }
                })
                .accessibilityIdentifier("desktop.surface")
                if showsIcons {
                    icons
                }
                KeyCommandHost(isActive: desktopHasKeys, focusToken: model.selection.count, onKey: model.handle(_:),
                               onType: { _ in })
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
                if let band = model.rubberBand {
                    Rectangle()
                        .fill(theme.accent.opacity(0.18))
                        .overlay(Rectangle().strokeBorder(theme.accent.opacity(0.85), lineWidth: 1))
                        .frame(width: band.width, height: band.height)
                        .offset(x: band.minX, y: band.minY)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("desktop.rubberBand")
                }
                if let target = model.dropTarget {
                    DropBadge(directory: target == model.trash.filesDirectory ? "Trash" : target,
                              operation: DropOperation.forGuestDrag())
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: Self.space)
            .onAppear { updateContext(proxy) }
            .onChange(of: proxy.size) { _, _ in updateContext(proxy) }
            .onChange(of: style) { _, _ in updateContext(proxy) }
            .onChange(of: iconSize) { _, _ in updateContext(proxy) }
            .onDrop(of: [.desktopLauncher] + DragItemProviders.acceptedTypes, delegate: DesktopDropDelegate(model: model))
        }
        .task {
            DragDropCenter.shared.attach(controller)
            DragDropCenter.shared.registerDesktopHandler { [model] items, operation in
                model.receive(items, operation: operation)
            }
            controller.desktopKeyHandler = { [model] key in model.handle(key) }
            model.onRenameRequest = { entry in beginPrompt(.rename(entry), entry.name) }
            model.start()
        }
        .onChange(of: model.selection) { _, _ in syncKeyboardFocus() }
        .onChange(of: controller.windowManager.focusedWindowID) { _, id in
            if id != nil { model.selection = [] }
            syncKeyboardFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .guestFilesChanged)) { _ in model.refreshSoon() }
        .onChange(of: controller.windowManager.windows.map(\.id)) { _, _ in
            DragDropCenter.shared.windowsChanged()
            model.refreshSoon()
        }
        .alert(prompt?.title ?? "", isPresented: isPromptPresented, presenting: prompt) { prompt in
            TextField("Name", text: $promptText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button(prompt.isRename ? "Rename" : "Create") { commit(prompt) }
        }
        .alert(pendingDeletion.count == 1 ? "Permanently delete “\(pendingDeletion.first?.name ?? "")”?"
                                          : "Permanently delete \(pendingDeletion.count) items?",
               isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })) {
            Button("Delete", role: .destructive) { model.deletePermanently(pendingDeletion) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
        .sheet(item: $propertiesTarget, onDismiss: model.refreshSoon) { target in
            FilePropertiesSheet(path: target.path, operations: model.operations) { propertiesTarget = nil }
        }
    }

    private static let space = "desktop.icons"

    private func updateContext(_ proxy: GeometryProxy) {
        surfaceOrigin = proxy.frame(in: .global).origin
        model.updateContext(style: style, size: proxy.size, iconSize: iconSize)
    }

    private func clearSelection() {
        model.selection = []
    }

    private func syncKeyboardFocus() {
        controller.desktopHasKeyboardFocus = !model.selection.isEmpty && controller.windowManager.focusedWindowID == nil
    }

    private var desktopHasKeys: Bool {
        controller.windowManager.focusedWindowID == nil && !controller.isOverlayPresented && !model.selection.isEmpty
    }

    // MARK: Icons

    private var icons: some View {
        let positions = model.positions
        let preview = model.dragPreview
        let cellSize = model.layout.cellSize
        return ZStack(alignment: .topLeading) {
            ForEach(preview.keys.sorted(), id: \.self) { key in
                if let origin = preview[key] {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
                        .frame(width: cellSize.width, height: cellSize.height)
                        .offset(x: origin.x, y: origin.y)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("desktop.dropPreview")
                }
            }
            ForEach(model.items) { item in
                if let origin = positions[item.id] {
                    icon(for: item, at: origin, cellSize: cellSize)
                }
            }
        }
    }

    private func icon(for item: DesktopItem, at origin: CGPoint, cellSize: CGSize) -> some View {
        let isDragging = model.dragKeys.contains(item.id)
        let offset = isDragging ? model.dragTranslation : .zero
        return DesktopItemIcon(item: item, iconName: iconName(for: item), iconSize: model.layout.iconSize.iconSize,
                               isSelected: model.selection.contains(item.id),
                               isDropTarget: model.dropTarget != nil && model.dropTarget == dropPath(for: item),
                               isCut: item.entry.map { FileClipboard.shared.isCut($0.path) } ?? false)
            .frame(width: cellSize.width, height: cellSize.height)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture(count: 2) { if case .file = item { model.open(item) } }
            .simultaneousGesture(TapGesture().onEnded { tap(item) })
            .simultaneousGesture(moveGesture(for: item))
            .hoverEffect(.highlight)
            .onDrag { model.dragProvider(for: item) }
            .modifier(OptionalDrop(delegate: dropPath(for: item).map(folderDropDelegate)))
            .contextMenu { itemMenu(item) }
            .scaleEffect(isDragging ? 1.06 : 1)
            .opacity(isDragging ? 0.85 : 1)
            .zIndex(isDragging ? 1 : 0)
            .offset(x: origin.x + offset.width, y: origin.y + offset.height)
            .accessibilityIdentifier("desktop.icon.\(item.name)")
            .accessibilityLabel(item.name)
            .accessibilityAddTraits(model.selection.contains(item.id) ? .isSelected : [])
    }

    /// Single click selects (Shift or Command extends the selection); app launchers open on
    /// a plain tap, as on XFCE, but only select when a modifier is held.
    private func tap(_ item: DesktopItem) {
        controller.windowManager.clearFocus()
        let extending = KeyboardModifiers.isCommandDown || KeyboardModifiers.isShiftDown
        if case .file = item {
            model.click(item)
        } else if extending {
            model.click(item)
        } else {
            model.selection = [item.id]
            model.open(item)
        }
    }

    /// Moves icons as soon as the finger or pointer moves, without the long press a system
    /// drag needs on touch. Holding still first still starts the system drag (`onDrag`),
    /// which is how icons reach Linux apps and other iPad apps.
    private func moveGesture(for item: DesktopItem) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if model.dragKeys.isEmpty {
                    if !model.selection.contains(item.id) { model.selection = [item.id] }
                    controller.windowManager.clearFocus()
                    model.dragKeys = model.items.map(\.id).filter { model.selection.contains($0) }
                }
                model.dragTranslation = value.translation
                model.dropTarget = model.dropDirectory(at: value.location, excluding: model.dragKeys)
            }
            .onEnded { value in
                model.dragTranslation = value.translation
                model.endDrag(atLocal: value.location, global: globalPoint(value.location))
            }
    }

    private func globalPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x + surfaceOrigin.x, y: local.y + surfaceOrigin.y)
    }

    private func iconName(for item: DesktopItem) -> String? {
        switch item {
        case .app(let id, _, _): return controller.iconName(forAppID: id)
        case .trash: return "user-trash"
        case .file: return nil
        }
    }

    /// Folders and the Trash take drops.
    private func dropPath(for item: DesktopItem) -> String? {
        switch item {
        case .trash: return model.trash.filesDirectory
        case .file(let entry) where entry.isDirectory: return entry.path
        default: return nil
        }
    }

    private func folderDropDelegate(_ directory: String) -> FolderDropDelegate {
        FolderDropDelegate(directory: directory) { target, _ in
            model.dropTarget = target
        } onDrop: { providers, operation in
            Task {
                let (payload, items) = await DragItemProviders.loadItems(from: providers)
                if directory == model.trash.filesDirectory {
                    let paths = items.compactMap(\.guestPath)
                    model.moveToTrash(paths.map { FileEntry(path: $0, name: AppPath.lastComponent($0), isDirectory: false) })
                    return
                }
                let guestPaths = items.compactMap(\.guestPath)
                model.run { [operations = model.operations] in
                    try await operations.transfer(guestPaths, into: directory, operation: payload == nil ? .copy : operation)
                }
            }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func itemMenu(_ item: DesktopItem) -> some View {
        switch item {
        case .app(let id, _, _):
            Button { model.open(item) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            Divider()
            Button(role: .destructive) { controller.toggleOnDesktop(id) } label: {
                Label("Remove from Desktop", systemImage: "minus.circle")
            }
        case .trash:
            Button { model.open(item) } label: { Label("Open", systemImage: "trash") }
            Button(role: .destructive) {
                model.run { [trash = model.trash] in
                    try await trash.empty()
                    return []
                }
            } label: { Label("Empty Trash", systemImage: "trash.slash") }
        case .file(let entry):
            let targets = model.targets(for: entry)
            let single = targets.count == 1 ? targets.first : nil
            Button { model.open(item) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
            if let single, !single.isDirectory {
                let apps = OpenWithCatalog.shared.linuxApplications(
                    for: OpenWithCatalog.shared.mimeType(for: single.name, isDirectory: false))
                Menu {
                    Button { model.openInEditor(single) } label: { Label("Text Editor", systemImage: "doc.text") }
                    Button { model.quickLook([single]) } label: { Label("Quick Look", systemImage: "eye") }
                    if !apps.isEmpty {
                        Section("Linux Applications") {
                            ForEach(apps) { app in Button(app.name) { model.openWith(single, app: app) } }
                        }
                    }
                } label: { Label("Open With", systemImage: "arrow.up.right.square") }
            }
            if let single {
                ForEach(controller.fileActions(forGuestPath: single.path), id: \.title) { action in
                    Button { action.action() } label: { Label(action.title, systemImage: action.symbol) }
                }
            }
            if let single, single.isDirectory {
                Button { model.openTerminal(at: single.path) } label: { Label("Open Terminal Here", systemImage: "terminal") }
            }
            Divider()
            Button { FileClipboard.shared.cut(targets.map(\.path)) } label: { Label("Cut", systemImage: "scissors") }
            Button { FileClipboard.shared.copy(targets.map(\.path)) } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button {
                UIPasteboard.general.string = targets.map(\.path).joined(separator: "\n")
            } label: { Label("Copy Path", systemImage: "link") }
            Divider()
            if let single {
                Button {
                    promptText = single.name
                    prompt = .rename(single)
                } label: { Label("Rename…", systemImage: "pencil") }
            }
            Button { model.duplicate(targets) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button { model.compress(targets) } label: { Label("Compress", systemImage: "archivebox") }
            if let single, !single.isDirectory, FileOperations.isArchive(single.name) {
                Button { model.extractHere(single) } label: { Label("Extract Here", systemImage: "archivebox.circle") }
            }
            Button { model.share(targets) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            Divider()
            Button(role: .destructive) { model.moveToTrash(targets) } label: { Label("Move to Trash", systemImage: "trash") }
            Button(role: .destructive) { pendingDeletion = targets } label: {
                Label("Delete Permanently…", systemImage: "trash.slash")
            }
            Divider()
            Button { propertiesTarget = PropertiesTarget(path: entry.path) } label: { Label("Properties", systemImage: "info.circle") }
        }
    }

    /// Built when the menu opens, so it reflects the clipboard and settings at that moment.
    private func backgroundMenu() -> UIMenu {
        let clipboard = FileClipboard.shared
        let newItems = UIMenu(title: "", options: .displayInline, children: [
            UIMenu(title: "Create New", image: UIImage(systemName: "plus"), children: [
                UIAction(title: "Folder", image: UIImage(systemName: "folder.badge.plus")) { _ in beginPrompt(.newFolder, "New Folder") },
                UIAction(title: "Text File", image: UIImage(systemName: "doc.badge.plus")) { _ in beginPrompt(.newFile, "untitled.txt") },
            ]),
            UIAction(title: "New Folder", image: UIImage(systemName: "folder.badge.plus")) { _ in beginPrompt(.newFolder, "New Folder") },
            UIAction(title: "New File", image: UIImage(systemName: "doc.badge.plus")) { _ in beginPrompt(.newFile, "untitled.txt") },
            UIAction(title: clipboard.paths.count > 1 ? "Paste \(clipboard.paths.count) Items" : "Paste",
                     image: UIImage(systemName: "doc.on.clipboard"),
                     attributes: clipboard.isEmpty ? .disabled : []) { _ in model.paste() },
        ])
        let terminal = UIAction(title: "Open Terminal Here", image: UIImage(systemName: "terminal")) { _ in
            model.openTerminal(at: model.desktopPath)
        }
        let layout = model.layout
        let keepArranged = UIMenu(title: "Keep Arranged", children: DesktopArrangeKey.allCases.map { key in
            UIAction(title: "By \(key.title)", state: layout.keepsArranged == key ? .on : .off) { _ in
                model.setKeepsArranged(layout.keepsArranged == key ? nil : key)
            }
        })
        let arrange = UIMenu(title: "Arrange Icons", image: UIImage(systemName: "square.grid.3x3"), children: [
            UIMenu(title: "", options: .displayInline, children: DesktopArrangeKey.allCases.map { key in
                UIAction(title: "By \(key.title)") { _ in model.arrange(by: key) }
            } + [UIAction(title: "By Size") { _ in model.arrange(by: FilesSortKey.size) }]),
            UIMenu(title: "", options: .displayInline, children: [
                keepArranged,
                UIAction(title: "Align to Grid", image: UIImage(systemName: "grid")) { _ in model.alignToGrid() },
                UIAction(title: "Snap to Grid", state: layout.snapsToGrid ? .on : .off) { _ in
                    model.setSnapsToGrid(!layout.snapsToGrid)
                },
            ]),
        ])
        let sizes = UIMenu(title: "Icon Size", image: UIImage(systemName: "textformat.size"), children: DesktopIconSize.allCases.map { size in
            UIAction(title: size.title, state: iconSize == size ? .on : .off) { _ in iconSize = size }
        })
        let showIcons = UIAction(title: "Show Desktop Icons", image: UIImage(systemName: "square.grid.2x2"),
                                 state: showsIcons ? .on : .off) { _ in showsIcons.toggle() }
        let shell = shellItems.map { item in
            UIAction(title: item.title, image: UIImage(systemName: item.symbol)) { _ in item.action() }
        }
        let settings = UIAction(title: "Desktop Settings…", image: UIImage(systemName: "slider.horizontal.3")) { _ in
            controller.open(appID: AppID.settings, arguments: [:])
        }
        let shellWithoutSettings = shell.filter { $0.title != "Settings" }
        return UIMenu(children: [
            newItems,
            UIMenu(title: "", options: .displayInline, children: [terminal]),
            UIMenu(title: "", options: .displayInline, children: [arrange, sizes, showIcons]),
            UIMenu(title: "", options: .displayInline, children: shellWithoutSettings + [settings]),
        ])
    }

    // MARK: Prompts

    private var isPromptPresented: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private func beginPrompt(_ newPrompt: DesktopPrompt, _ text: String) {
        promptText = text
        prompt = newPrompt
    }

    private func commit(_ prompt: DesktopPrompt) {
        switch prompt {
        case .newFolder: model.create(folder: true, named: promptText)
        case .newFile: model.create(folder: false, named: promptText)
        case .rename(let entry): model.rename(entry, to: promptText)
        }
    }
}

private extension DesktopPrompt {
    var isRename: Bool {
        if case .rename = self { return true }
        return false
    }
}

private struct DesktopDropDelegate: DropDelegate {
    let model: DesktopFolderModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.desktopLauncher] + DragItemProviders.acceptedTypes)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            let internalMove = info.hasItemsConforming(to: [.desktopLauncher])
            let guest = info.hasItemsConforming(to: [.guestItems])
            return DropProposal(operation: internalMove || (guest && DropOperation.forGuestDrag() == .move) ? .move : .copy)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let providers = info.itemProviders(for: [.desktopLauncher] + DragItemProviders.acceptedTypes)
            model.drop(providers, at: info.location, operation: DropOperation.forGuestDrag())
        }
        return true
    }
}

/// One desktop icon: the app's or file's icon over its name, XFCE style.
private struct DesktopItemIcon: View {
    let item: DesktopItem
    let iconName: String?
    var iconSize: CGFloat = 52
    let isSelected: Bool
    let isDropTarget: Bool
    let isCut: Bool
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        VStack(spacing: 6) {
            Group {
                switch item {
                case .app(_, _, let symbol):
                    AppIcon(iconName: iconName, symbol: symbol, size: iconSize)
                case .trash:
                    AppIcon(iconName: iconName, symbol: "trash", size: iconSize)
                case .file(let entry):
                    FileIconView(entry: entry, size: iconSize * 0.77, theme: theme)
                        .frame(width: iconSize, height: iconSize)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? theme.accent.opacity(0.85) : Color.clear))
                .shadow(color: .black.opacity(isSelected ? 0 : 0.8), radius: 2, y: 1)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDropTarget ? theme.accent.opacity(0.45) : (isSelected ? Color.white.opacity(0.14) : Color.clear)))
        .opacity(isCut ? 0.5 : 1)
    }
}

/// The empty desktop's UIKit side: a context menu at the touch point (a SwiftUI
/// `.contextMenu` would lift the whole wallpaper as its preview), a tap that clears the
/// icon selection, and pinch-in for the overview.
private struct DesktopBackgroundArea: UIViewRepresentable {
    enum BandPhase { case began, changed, ended }

    let menu: @MainActor () -> UIMenu
    let onTap: @MainActor () -> Void
    let onPinchIn: @MainActor () -> Void
    /// A one-finger (or pointer) drag on the empty desktop draws a selection rectangle.
    let onBand: @MainActor (BandPhase, CGPoint, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        let band = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.band(_:)))
        band.maximumNumberOfTouches = 1
        band.allowedScrollTypesMask = []
        view.addGestureRecognizer(band)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.menu = menu
        context.coordinator.onTap = onTap
        context.coordinator.onPinchIn = onPinchIn
        context.coordinator.onBand = onBand
    }

    @MainActor
    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var menu: (@MainActor () -> UIMenu)?
        var onTap: (@MainActor () -> Void)?
        var onPinchIn: (@MainActor () -> Void)?
        var onBand: (@MainActor (BandPhase, CGPoint, CGPoint) -> Void)?
        private var menuLocation: CGPoint = .zero
        private var bandStart: CGPoint = .zero

        @objc func band(_ recognizer: UIPanGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                let translation = recognizer.translation(in: recognizer.view)
                bandStart = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
                onBand?(.began, bandStart, point)
                onBand?(.changed, bandStart, point)
            case .changed:
                onBand?(.changed, bandStart, point)
            default:
                onBand?(.ended, bandStart, point)
            }
        }

        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .ended, recognizer.scale < 0.8 { onPinchIn?() }
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            onTap?()
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                    configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
            menuLocation = location
            let menu = menu
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu?() }
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                    highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            pointPreview(for: interaction)
        }

        func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                    dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
            pointPreview(for: interaction)
        }

        /// A zero-size preview at the touch, so the menu appears where the finger is.
        private func pointPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let container = interaction.view else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            let anchor = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)))
            anchor.backgroundColor = .clear
            return UITargetedPreview(view: anchor, parameters: parameters,
                                     target: UIPreviewTarget(container: container, center: menuLocation))
        }
    }
}
