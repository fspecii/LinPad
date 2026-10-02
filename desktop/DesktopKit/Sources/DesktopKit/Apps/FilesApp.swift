import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum FilesApp {
    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: AppID.files, name: "Files", symbol: "folder", category: .accessories,
            defaultSize: CGSize(width: 840, height: 540), showsOnDesktop: true
        ) { context in
            AnyView(FilesAppView(context: context))
        }
    }
}

// MARK: - Model

enum FilesViewMode {
    case list, grid
}

enum FilesSortKey: String, CaseIterable, Identifiable {
    case name = "Name", size = "Size", modified = "Modified", kind = "Type"
    var id: Self { self }
}

struct FilesPlace: Identifiable, Hashable {
    let name: String
    let symbol: String
    let path: String
    /// Freedesktop icon names, in fallback order (ThemeIconNames).
    var iconNames: [String] = []
    var id: String { path }
}

@MainActor
@Observable
final class FilesModel {
    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private let desktop: any DesktopActions
    @ObservationIgnored private let window: any WindowHandle
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var typeAhead = ""
    @ObservationIgnored private var typeAheadTime = Date.distantPast
    @ObservationIgnored private var selectionOrigin: String?
    @ObservationIgnored let operations: FileOperations
    @ObservationIgnored let trash: FileTrash
    @ObservationIgnored let transfer: GuestTransferService

    let homeDirectory: String
    let places: [FilesPlace]
    private(set) var path: String
    private(set) var entries: [FileEntry] = []
    private(set) var isLoading = false
    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    var errorMessage: String?
    var showHidden = false
    var sortKey: FilesSortKey = .name
    var ascending = true
    var viewMode: FilesViewMode = .list
    var selection: Set<String> = []
    private(set) var anchor: String?
    /// The folder a drag is hovering, and what dropping would do.
    var dropTarget: String?
    var dropOperation: DropOperation?
    private(set) var activity: TransferActivity?
    private(set) var trashItems: [String: FileTrash.Item] = [:]
    private(set) var canCreateZip = false
    var gridColumns = 1

    init(context: AppLaunchContext) {
        host = context.host
        desktop = context.desktop
        window = context.window
        operations = FileOperations(host: context.host)
        transfer = GuestTransferService(host: context.host)
        let home = AppPath.normalize(context.host.homeDirectory)
        homeDirectory = home
        trash = FileTrash(host: context.host, homeDirectory: home)
        path = AppPath.normalize(context.arguments[AppArgument.path] ?? home)
        places = [
            FilesPlace(name: "Home", symbol: "house", path: home, iconNames: ThemeIconNames.home),
            FilesPlace(name: "Desktop", symbol: "menubar.dock.rectangle", path: AppPath.join(home, "Desktop"),
                       iconNames: ThemeIconNames.desktop),
            FilesPlace(name: "File System", symbol: "internaldrive", path: "/", iconNames: ThemeIconNames.fileSystem),
            FilesPlace(name: "Temporary", symbol: "clock.arrow.circlepath", path: "/tmp", iconNames: ThemeIconNames.temporary),
            FilesPlace(name: "Trash", symbol: "trash", path: AppPath.join(home, ".local/share/Trash/files"),
                       iconNames: ThemeIconNames.trash),
        ]
    }

    var windowID: UUID { window.id }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { path != "/" && !isTrash }
    var isTrash: Bool { path == trash.filesDirectory }
    var hiddenCount: Int { entries.filter { $0.name.hasPrefix(".") }.count }

    var displayName: String {
        if isTrash { return "Trash" }
        return path == homeDirectory ? "Home" : (path == "/" ? "File System" : AppPath.lastComponent(path))
    }

    var visibleEntries: [FileEntry] {
        let filtered = showHidden || isTrash ? entries : entries.filter { !$0.name.hasPrefix(".") }
        return filtered.sorted(by: areInIncreasingOrder)
    }

    var selectedEntries: [FileEntry] {
        visibleEntries.filter { selection.contains($0.path) }
    }

    /// What a context menu on `entry` acts on: the selection if the entry is part of it,
    /// otherwise just the entry, as in every desktop file manager.
    func targets(for entry: FileEntry) -> [FileEntry] {
        selection.contains(entry.path) ? selectedEntries : [entry]
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        reload()
        Task {
            try? await Task.sleep(for: .seconds(15))
            canCreateZip = await operations.canCreateZip()
        }
    }

    // MARK: Navigation

    func navigate(to target: String) {
        let resolved = resolve(target)
        guard resolved != path else {
            reload()
            return
        }
        backStack.append(path)
        forwardStack.removeAll()
        show(resolved)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        show(next)
    }

    func goUp() {
        guard canGoUp else { return }
        let child = path
        navigate(to: AppPath.parent(of: path))
        select([child])
    }

    func reload() {
        loadTask?.cancel()
        let requested = path
        window.setTitle(displayName)
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            if requested == trash.filesDirectory {
                _ = await host.run("mkdir -p -- \(trash.filesDirectory.shellQuoted) \(trash.infoDirectory.shellQuoted)",
                                   cwd: nil, stdin: nil)
                let items = (try? await trash.list()) ?? []
                trashItems = Dictionary(items.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            }
            do {
                let list = try await host.listDirectory(requested)
                guard !Task.isCancelled, requested == path else { return }
                entries = list
                selection.formIntersection(Set(list.map(\.path)))
                errorMessage = nil
            } catch {
                guard !Task.isCancelled, requested == path else { return }
                entries = []
                errorMessage = "Couldn't open \(requested): \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    // MARK: Selection

    func select(_ paths: [String]) {
        selection = Set(paths)
        anchor = paths.last
        selectionOrigin = nil
    }

    /// Click: plain selects one, ⌘ toggles, ⇧ extends from the anchor.
    func click(_ entry: FileEntry) {
        if KeyboardModifiers.isCommandDown {
            if selection.contains(entry.path) { selection.remove(entry.path) } else { selection.insert(entry.path) }
            anchor = entry.path
        } else if KeyboardModifiers.isShiftDown, let anchor {
            extendSelection(from: anchor, to: entry.path)
        } else {
            select([entry.path])
        }
    }

    func selectAll() {
        selection = Set(visibleEntries.map(\.path))
    }

    /// Arrow keys: a step of 1 moves along the list, `gridColumns` moves a row in icon view.
    func moveSelection(by step: Int, extend: Bool) {
        let items = visibleEntries
        guard !items.isEmpty else { return }
        let current = anchor.flatMap { focus in items.firstIndex { $0.path == focus } }
        let next = current.map { max(0, min(items.count - 1, $0 + step)) } ?? (step > 0 ? 0 : items.count - 1)
        if extend, let origin = selectionOrigin ?? anchor {
            extendSelection(from: origin, to: items[next].path)
            selectionOrigin = origin
            anchor = items[next].path
        } else {
            select([items[next].path])
        }
    }

    private func extendSelection(from start: String, to end: String) {
        let items = visibleEntries.map(\.path)
        guard let a = items.firstIndex(of: start), let b = items.firstIndex(of: end) else {
            select([end])
            return
        }
        selection = Set(items[min(a, b)...max(a, b)])
    }

    /// Typing a name selects the first match; letters typed within a second extend it.
    func typeToSelect(_ text: String) {
        let now = Date()
        typeAhead = now.timeIntervalSince(typeAheadTime) < 1 ? typeAhead + text : text
        typeAheadTime = now
        let prefix = typeAhead.lowercased()
        if let match = visibleEntries.first(where: { $0.name.lowercased().hasPrefix(prefix) }) {
            select([match.path])
        }
    }

    // MARK: Opening

    func open(_ entry: FileEntry) {
        if isTrash { return }
        if entry.isDirectory {
            navigate(to: entry.path)
            return
        }
        guard entry.isSymlink else {
            openFile(entry)
            return
        }
        // listDirectory may report a symlink to a directory as a plain file.
        Task {
            do {
                _ = try await host.listDirectory(entry.path)
                navigate(to: entry.path)
            } catch {
                openFile(entry)
            }
        }
    }

    func openSelection() {
        let items = selectedEntries
        if items.count == 1, let only = items.first {
            open(only)
        } else {
            items.filter { !$0.isDirectory }.forEach(openFile)
        }
    }

    func openSelectionIfFolder() {
        let items = selectedEntries
        if items.count == 1, let only = items.first, only.isDirectory { navigate(to: only.path) }
    }

    func openFile(_ entry: FileEntry) {
        switch OpenWithCatalog.shared.defaultOpen(for: entry.name) {
        case .editor: openInEditor(entry.path)
        case .linux(let app): open(entry, with: app)
        case .quickLook: quickLook([entry])
        }
    }

    func open(_ entry: FileEntry, with app: OpenWithCatalog.Application) {
        desktop.open(appID: LinuxAppID.prefix + OpenWithCatalog.command(exec: app.exec, path: entry.path), arguments: [:])
    }

    func openInEditor(_ filePath: String) {
        desktop.open(appID: AppID.editor, arguments: [AppArgument.path: filePath])
    }

    func openTerminal(at directory: String) {
        desktop.open(appID: LinuxAppID.preferredTerminal, arguments: [AppArgument.cwd: directory])
    }

    func openInNewWindow(_ directory: String) {
        desktop.open(appID: AppID.files, arguments: [AppArgument.path: directory])
    }

    // MARK: Clipboard

    func copyPaths(_ items: [FileEntry]) {
        guard !items.isEmpty else { return }
        UIPasteboard.general.string = items.map(\.path).joined(separator: "\n")
        desktop.notify(items.count == 1 ? "Copied \(items[0].path)" : "Copied \(items.count) paths")
    }

    func copy(_ items: [FileEntry]) {
        guard !items.isEmpty else { return }
        FileClipboard.shared.copy(items.map(\.path))
    }

    func cut(_ items: [FileEntry]) {
        guard !items.isEmpty, !isTrash else { return }
        FileClipboard.shared.cut(items.map(\.path))
    }

    func paste(into directory: String? = nil) {
        let clipboard = FileClipboard.shared
        guard !clipboard.isEmpty, !isTrash else { return }
        let target = directory ?? path
        let isCut = clipboard.isCut
        let paths = clipboard.paths
        run(isCut ? "Moving" : "Copying") { [operations] in
            let results = try await operations.transfer(paths, into: target, operation: isCut ? .move : .copy)
            if isCut { clipboard.clear() }
            return results
        }
    }

    // MARK: File operations

    func createFolder(named rawName: String) {
        guard let target = childPath(rawName) else { return }
        let quoted = target.shellQuoted
        perform("""
            if [ -e \(quoted) ]; then echo 'An item with that name already exists.' >&2; exit 1; fi
            mkdir -p -- \(quoted)
            """, select: target)
    }

    func createFile(named rawName: String) {
        guard let target = childPath(rawName) else { return }
        let quoted = target.shellQuoted
        perform("""
            if [ -e \(quoted) ]; then echo 'An item with that name already exists.' >&2; exit 1; fi
            touch -- \(quoted)
            """, select: target)
    }

    func rename(_ entry: FileEntry, to rawName: String) {
        let name = rawName.trimmedWhitespace
        guard name != entry.name else { return }
        guard AppPath.isValidName(name) else {
            errorMessage = "“\(rawName)” isn't a valid name."
            return
        }
        let target = AppPath.join(AppPath.parent(of: entry.path), name)
        let destination = target.shellQuoted
        perform("""
            if [ -e \(destination) ]; then echo 'An item with that name already exists.' >&2; exit 1; fi
            mv -- \(entry.path.shellQuoted) \(destination)
            """, select: target)
    }

    func duplicate(_ items: [FileEntry]) {
        guard !items.isEmpty, !isTrash else { return }
        run("Duplicating") { [operations] in try await operations.duplicate(items.map(\.path)) }
    }

    private var protectedPaths: Set<String> { ["/", homeDirectory, trash.filesDirectory, trash.trashDirectory] }

    func moveToTrash(_ items: [FileEntry]) {
        if isTrash {
            deletePermanently(items)
            return
        }
        let paths = items.map(\.path).filter { !protectedPaths.contains(AppPath.normalize($0)) }
        guard !paths.isEmpty else { return }
        run("Moving to Trash") { [trash, desktop] in
            try await trash.trash(paths)
            desktop.notify(paths.count == 1 ? "Moved “\(AppPath.lastComponent(paths[0]))” to Trash"
                                            : "Moved \(paths.count) items to Trash")
            return []
        }
    }

    func deletePermanently(_ items: [FileEntry]) {
        guard !items.isEmpty else { return }
        if isTrash {
            let names = items.map(\.name)
            run("Deleting") { [trash] in
                try await trash.delete(names)
                return []
            }
            return
        }
        run("Deleting") { [operations, protectedPaths] in
            try await operations.deletePermanently(items.map(\.path), protecting: protectedPaths)
            return []
        }
    }

    func restore(_ items: [FileEntry]) {
        let names = items.map(\.name)
        run("Restoring") { [trash, desktop] in
            let restored = try await trash.restore(names)
            desktop.notify(restored.count == 1 ? "Restored to \(restored[0])" : "Restored \(restored.count) items")
            return []
        }
    }

    func emptyTrash() {
        run("Emptying Trash") { [trash] in
            try await trash.empty()
            return []
        }
    }

    func compress(_ items: [FileEntry], format: FileOperations.ArchiveFormat) {
        guard !items.isEmpty else { return }
        run("Compressing") { [operations] in [try await operations.compress(items.map(\.path), format: format)] }
    }

    func extractHere(_ entry: FileEntry) {
        run("Extracting") { [operations] in [try await operations.extractHere(entry.path)] }
    }

    // MARK: iPad folders and Photos

    var linuxHost: any LinuxHost { host }
    var desktopActions: any DesktopActions { desktop }

    /// Mount points the host has mounted; places missing from it show as unavailable.
    var mountedIPadPoints: Set<String> {
        (host as? any HostDirectoryMounting)?.mountedHostDirectories ?? []
    }

    var canMountIPadFolders: Bool { host is any HostDirectoryMounting }

    func addIPadFolder() {
        Task {
            do {
                if let point = try await IPadPlaceStore.shared.addFolder(host: host) { navigate(to: point) }
            } catch {
                errorMessage = "Couldn't add the folder: \(error.localizedDescription)"
            }
        }
    }

    func reconnect(_ place: IPadPlace) {
        Task {
            do {
                try await IPadPlaceStore.shared.reconnect(place, host: host)
                navigate(to: place.mountPoint)
            } catch {
                errorMessage = "Couldn't reconnect “\(place.name)”: \(error.localizedDescription). Remove it and add the folder again."
            }
        }
    }

    func eject(_ place: IPadPlace) {
        Task {
            do {
                try await IPadPlaceStore.shared.eject(place, host: host)
                if path.hasPrefix(place.mountPoint) { navigate(to: homeDirectory) }
            } catch {
                errorMessage = "Couldn't eject “\(place.name)”: \(error.localizedDescription)"
            }
        }
    }

    func saveToPhotos(_ items: [FileEntry]) {
        run("Saving to Photos") { [transfer, desktop] in
            let count = try await PhotosSaver.save(items, transfer: transfer)
            desktop.notify(count == 1 ? "Saved to Photos" : "Saved \(count) items to Photos")
            return []
        }
    }

    // MARK: Sharing, Quick Look, drag and drop

    /// Space: toggles Quick Look for the selected files. With one file selected, the arrow
    /// keys move the selection through the folder and the preview follows it, as in Finder.
    func quickLook(_ items: [FileEntry]) {
        let presenter = QuickLookPresenter.shared
        if presenter.isPresenting {
            presenter.dismiss()
            return
        }
        let files = items.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        Task { await showPreview(files, replacing: false) }
    }

    /// True while files are exported for Quick Look (a spinner shows over the list).
    private(set) var isPreparingPreview = false

    private func showPreview(_ files: [FileEntry], replacing: Bool) async {
        let activity = TransferActivity(title: "Preparing preview")
        self.activity = activity
        isPreparingPreview = true
        var urls: [URL] = []
        for file in files {
            if let url = try? await QuickLookPresenter.shared.exportedURL(for: file, transfer: transfer, progress: { done, total in
                activity.update(done, total)
            }) {
                urls.append(url)
            }
        }
        isPreparingPreview = false
        if self.activity === activity { self.activity = nil }
        guard !urls.isEmpty else { return }
        if replacing {
            QuickLookPresenter.shared.replace(urls)
        } else {
            QuickLookPresenter.shared.preview(urls, onStep: files.count == 1 ? { [weak self] step in
                self?.quickLookStep(step)
            } : nil)
        }
    }

    private func quickLookStep(_ step: QuickLookPresenter.Step) {
        let row = viewMode == .grid ? gridColumns : 1
        switch step {
        case .previous: moveSelection(by: -1, extend: false)
        case .next: moveSelection(by: 1, extend: false)
        case .up: moveSelection(by: -row, extend: false)
        case .down: moveSelection(by: row, extend: false)
        }
        guard let entry = selectedEntries.first, !entry.isDirectory else { return }
        Task { await showPreview([entry], replacing: true) }
    }

    func share(_ items: [FileEntry]) {
        guard !items.isEmpty else { return }
        let activity = TransferActivity(title: "Preparing to share")
        self.activity = activity
        Task {
            var urls: [URL] = []
            do {
                for item in items {
                    urls.append(try await transfer.exportItem(item.path, isDirectory: item.isDirectory) { done, total in
                        activity.update(done, total)
                    })
                }
                if self.activity === activity { self.activity = nil }
                HostPresenter.share(urls)
            } catch {
                if self.activity === activity { self.activity = nil }
                errorMessage = error.localizedDescription
            }
        }
    }

    func dragProvider(for entry: FileEntry) -> NSItemProvider {
        if !selection.contains(entry.path) { select([entry.path]) }
        let items = targets(for: entry).map { GuestItemsPayload.Item(path: $0.path, isDirectory: $0.isDirectory) }
        return DragItemProviders.provider(for: items, sourceWindow: window.id, transfer: transfer)
    }

    func setDropTarget(_ directory: String?, _ operation: DropOperation?) {
        if dropTarget != directory { dropTarget = directory }
        if dropOperation != operation { dropOperation = operation }
    }

    func drop(_ providers: [NSItemProvider], into directory: String, operation: DropOperation) {
        Task {
            let (payload, items) = await DragItemProviders.loadItems(from: providers)
            receive(items, into: directory, operation: payload == nil ? .copy : operation)
        }
    }

    /// Takes dropped items into a folder: guest files are copied or moved, files from other
    /// apps are imported through the guest, text and links become files.
    func receive(_ items: [DragItem], into directory: String, operation: DropOperation) {
        let guestPaths = items.compactMap(\.guestPath)
        if directory == trash.filesDirectory {
            moveToTrash(guestPaths.map { FileEntry(path: $0, name: AppPath.lastComponent($0), isDirectory: false) })
            return
        }
        let movesOnly = operation == .move && items.allSatisfy { $0.guestPath != nil }
        let activity = TransferActivity(title: movesOnly ? "Moving" : "Copying")
        run(activity) { [operations, transfer] in
            var results: [String] = []
            if !guestPaths.isEmpty {
                results += try await operations.transfer(guestPaths, into: directory, operation: operation)
            }
            for item in items {
                switch item {
                case .guestFile:
                    continue
                case .hostFile(let url):
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    results.append(try await transfer.importItem(at: url, into: directory) { done, total in
                        activity.update(done, total)
                    })
                case .data(let data, let name):
                    results.append(try await transfer.importData(data, named: name, into: directory))
                case .text(let text):
                    results.append(try await transfer.importData(Data(text.utf8), named: "Dropped Text.txt", into: directory))
                case .url(let url):
                    let link = DesktopLink(url: url)
                    results.append(try await transfer.importData(Data(link.contents.utf8), named: link.fileName, into: directory))
                }
            }
            return results
        }
    }

    // MARK: Private

    private func run(_ title: String, _ work: @escaping @MainActor () async throws -> [String]) {
        run(TransferActivity(title: title), work)
    }

    /// Runs an operation with a status-bar activity, then reloads and selects its results.
    private func run(_ activity: TransferActivity, _ work: @escaping @MainActor () async throws -> [String]) {
        self.activity = activity
        Task {
            do {
                let results = try await work()
                errorMessage = nil
                let here = results.filter { AppPath.parent(of: $0) == path }
                if !here.isEmpty { select(here) }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if self.activity === activity { self.activity = nil }
            reload()
        }
    }

    private func show(_ newPath: String) {
        path = newPath
        selection = []
        anchor = nil
        errorMessage = nil
        reload()
    }

    private func resolve(_ input: String) -> String {
        var value = input.trimmedWhitespace
        if value == "~" || value.hasPrefix("~/") {
            value = homeDirectory + value.dropFirst()
        }
        return AppPath.normalize(value, relativeTo: path)
    }

    private func childPath(_ rawName: String) -> String? {
        let name = rawName.trimmedWhitespace
        guard AppPath.isValidName(name) else {
            errorMessage = "“\(rawName)” isn't a valid name."
            return nil
        }
        return AppPath.join(path, name)
    }

    private func perform(_ command: String, select target: String?) {
        Task {
            let result = await host.run(command, cwd: nil, stdin: nil)
            if result.succeeded {
                errorMessage = nil
                if let target { select([target]) }
            } else {
                errorMessage = result.failureDescription
            }
            reload()
        }
    }

    private func areInIncreasingOrder(_ lhs: FileEntry, _ rhs: FileEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        let result: ComparisonResult
        switch sortKey {
        case .name:
            result = byName
        case .size:
            result = lhs.size == rhs.size ? byName : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .modified:
            let left = lhs.modified ?? .distantPast
            let right = rhs.modified ?? .distantPast
            result = left == right ? byName : (left < right ? .orderedAscending : .orderedDescending)
        case .kind:
            let kind = AppPath.pathExtension(lhs.name).compare(AppPath.pathExtension(rhs.name))
            result = kind == .orderedSame ? byName : kind
        }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }
}

/// A freedesktop Link entry, which is what a web link dropped on a folder becomes.
struct DesktopLink {
    let url: URL

    var fileName: String { (url.host ?? "Link") + ".desktop" }

    var contents: String {
        "[Desktop Entry]\nType=Link\nName=\(url.host ?? url.absoluteString)\nURL=\(url.absoluteString)\nIcon=text-html\n"
    }
}

// MARK: - Icons

enum FileIcon {
    static func symbol(for entry: FileEntry) -> String {
        if entry.isDirectory { return entry.isSymlink ? "folder.badge.gearshape" : "folder.fill" }
        switch AppPath.pathExtension(entry.name) {
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "py", "sh", "c", "h", "cpp", "swift", "rs", "go", "rb":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "lock":
            return "curlybraces"
        case "md", "txt", "log", "rst":
            return "doc.text"
        case "html", "htm":
            return "globe"
        case "css", "scss", "less":
            return "paintbrush"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico":
            return "photo"
        case "zip", "tar", "gz", "tgz", "xz", "bz2", "apk":
            return "doc.zipper"
        case "desktop":
            return "link"
        default:
            return entry.isSymlink ? "link" : "doc"
        }
    }

    static func tint(for entry: FileEntry, theme: DesktopTheme) -> Color {
        if entry.isDirectory { return theme.accent }
        switch AppPath.pathExtension(entry.name) {
        case "js", "mjs", "cjs", "jsx": return Color(red: 0.95, green: 0.83, blue: 0.3)
        case "ts", "tsx": return Color(red: 0.35, green: 0.6, blue: 0.95)
        case "json", "yaml", "yml", "toml", "lock": return Color(red: 0.85, green: 0.6, blue: 0.35)
        case "py": return Color(red: 0.45, green: 0.75, blue: 0.5)
        case "html", "htm": return Color(red: 0.92, green: 0.45, blue: 0.3)
        case "css", "scss", "less": return Color(red: 0.6, green: 0.5, blue: 0.95)
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico": return Color(red: 0.4, green: 0.8, blue: 0.8)
        default: return theme.secondaryText
        }
    }
}

// MARK: - Views

private enum FilesPrompt: Identifiable {
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

    var actionTitle: String {
        switch self {
        case .newFolder, .newFile: return "Create"
        case .rename: return "Rename"
        }
    }
}

struct PropertiesTarget: Identifiable {
    let path: String
    var id: String { path }
}

struct FilesAppView: View {
    @Environment(\.desktopTheme) private var theme
    @Environment(\.desktopWindowIsFocused) private var isWindowFocused
    @State private var model: FilesModel
    @State private var prompt: FilesPrompt?
    @State private var promptText = ""
    @State private var pendingDeletion: [FileEntry] = []
    @State private var confirmsEmptyTrash = false
    @State private var propertiesTarget: PropertiesTarget?
    @State private var isEditingPath = false
    @State private var pathDraft = ""
    @State private var showsSidebar = true
    @State private var keyFocusToken = 0
    @State private var showsPhotos = false
    @State private var photos = PhotosLibraryModel()
    @FocusState private var pathFieldFocused: Bool
    private var clipboard: FileClipboard { FileClipboard.shared }

    init(context: AppLaunchContext) {
        _model = State(initialValue: FilesModel(context: context))
    }

    private var takesKeys: Bool {
        !showsPhotos && isWindowFocused && prompt == nil && pendingDeletion.isEmpty && propertiesTarget == nil
            && !isEditingPath && !confirmsEmptyTrash
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let message = model.errorMessage {
                InlineBanner(kind: .error, message: message, onDismiss: { model.errorMessage = nil })
            }
            HStack(spacing: 0) {
                if showsSidebar {
                    sidebar
                    ThemedSeparator(vertical: true)
                }
                if showsPhotos {
                    PhotosBrowserView(model: photos, host: model.linuxHost, desktop: model.desktopActions,
                                      isFocused: isWindowFocused)
                } else {
                    content
                }
            }
            statusBar
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .background {
            KeyCommandHost(isActive: takesKeys, focusToken: keyFocusToken, onKey: handle(_:),
                           onType: model.typeToSelect)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .animation(.easeOut(duration: 0.18), value: model.errorMessage)
        .task { model.startIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .guestFilesChanged)) { _ in model.reload() }
        .onChange(of: model.path) { _, _ in showsPhotos = false }
        .onReceive(NotificationCenter.default.publisher(for: .quickLookDidClose)) { _ in keyFocusToken += 1 }
        .onChange(of: isWindowFocused) { _, focused in if focused { model.reload() } }
        .nativeDropTarget(window: model.windowID) { items, operation in
            model.receive(items, into: model.path, operation: operation)
        }
        .alert(prompt?.title ?? "", isPresented: isPromptPresented) {
            TextField("Name", text: $promptText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { keyFocusToken += 1 }
            Button(prompt?.actionTitle ?? "OK") {
                if let prompt { commit(prompt) }
                keyFocusToken += 1
            }
        }
        .alert(deletionTitle, isPresented: isDeletionPresented) {
            Button("Delete", role: .destructive) {
                model.deletePermanently(pendingDeletion)
                keyFocusToken += 1
            }
            Button("Cancel", role: .cancel) { keyFocusToken += 1 }
        } message: {
            Text("This can't be undone. The item\(pendingDeletion.count == 1 ? "" : "s") will be deleted immediately.")
        }
        .alert("Empty Trash?", isPresented: $confirmsEmptyTrash) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All items in the Trash will be permanently deleted.")
        }
        .sheet(item: $propertiesTarget, onDismiss: {
            model.reload()
            keyFocusToken += 1
        }) { target in
            FilePropertiesSheet(path: target.path, operations: model.operations) { propertiesTarget = nil }
                .environment(\.desktopTheme, theme)
        }
    }

    // MARK: Keyboard

    private func handle(_ key: FileKey) {
        let selected = model.selectedEntries
        let row = model.viewMode == .grid ? model.gridColumns : 1
        switch key {
        case .copy: model.copy(selected)
        case .cut: model.cut(selected)
        case .paste: model.paste()
        case .selectAll: model.selectAll()
        case .trash, .trashCommand: model.moveToTrash(selected)
        case .deletePermanently: if !selected.isEmpty { pendingDeletion = selected }
        case .rename: if selected.count == 1, let entry = selected.first { beginPrompt(.rename(entry), text: entry.name) }
        case .open: model.openSelection()
        case .quickLook: model.quickLook(selected)
        case .up: model.moveSelection(by: -row, extend: false)
        case .down: model.moveSelection(by: row, extend: false)
        case .left: model.viewMode == .grid ? model.moveSelection(by: -1, extend: false) : model.goBack()
        case .right: model.viewMode == .grid ? model.moveSelection(by: 1, extend: false) : model.openSelectionIfFolder()
        case .extendUp: model.moveSelection(by: -row, extend: true)
        case .extendDown: model.moveSelection(by: row, extend: true)
        case .extendLeft: model.moveSelection(by: -1, extend: true)
        case .extendRight: model.moveSelection(by: 1, extend: true)
        case .goUp: model.goUp()
        case .back: model.goBack()
        case .forward: model.goForward()
        case .newFolder: if !model.isTrash { beginPrompt(.newFolder, text: "New Folder") }
        case .escape: model.selection = []
        case .showHidden: model.showHidden.toggle()
        case .duplicate: model.duplicate(selected)
        case .properties: if let entry = selected.first { propertiesTarget = PropertiesTarget(path: entry.path) }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        AppToolbar {
            ToolbarIconButton("sidebar.left", icon: ThemeIconNames.sidebar, help: "Toggle Sidebar", isActive: showsSidebar) {
                withAnimation(.easeOut(duration: 0.2)) { showsSidebar.toggle() }
            }
            ToolbarIconButton("chevron.left", icon: ThemeIconNames.goBack, help: "Back") { model.goBack() }
                .disabled(!model.canGoBack)
            ToolbarIconButton("chevron.right", icon: ThemeIconNames.goForward, help: "Forward") { model.goForward() }
                .disabled(!model.canGoForward)
            ToolbarIconButton("arrow.up", icon: ThemeIconNames.goUp, help: "Enclosing Folder") { model.goUp() }
                .disabled(!model.canGoUp)
            pathBar
                .padding(.horizontal, 4)
            if model.isTrash {
                ToolbarIconButton("trash.slash", icon: ThemeIconNames.emptyTrash, help: "Empty Trash") { confirmsEmptyTrash = true }
                    .disabled(model.entries.isEmpty)
            } else {
                ToolbarIconButton("folder.badge.plus", icon: ThemeIconNames.newFolder, help: "New Folder") { beginPrompt(.newFolder, text: "New Folder") }
                ToolbarIconButton("doc.badge.plus", icon: ThemeIconNames.newFile, help: "New File") { beginPrompt(.newFile, text: "untitled.txt") }
            }
            ToolbarIconButton("arrow.clockwise", icon: ThemeIconNames.refresh, help: "Refresh") { model.reload() }
            ToolbarIconButton(model.viewMode == .list ? "square.grid.2x2" : "list.bullet",
                              icon: model.viewMode == .list ? ThemeIconNames.gridView : ThemeIconNames.listView,
                              help: model.viewMode == .list ? "Icon View" : "List View") {
                model.viewMode = model.viewMode == .list ? .grid : .list
            }
            optionsMenu
        }
    }

    private var pathBar: some View {
        Group {
            if isEditingPath {
                TextField("Path", text: $pathDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($pathFieldFocused)
                    .onSubmit {
                        model.navigate(to: pathDraft)
                        isEditingPath = false
                    }
                    .onChange(of: pathFieldFocused) { _, focused in
                        if !focused { isEditingPath = false }
                    }
                    .padding(.horizontal, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 1) {
                            ForEach(AppPath.components(model.path)) { component in
                                breadcrumb(component)
                                    .id(component.path)
                            }
                        }
                        .padding(.horizontal, 3)
                    }
                    .onAppear { proxy.scrollTo(model.path, anchor: .trailing) }
                    .onChange(of: model.path) { _, newPath in proxy.scrollTo(newPath, anchor: .trailing) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginEditingPath() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.windowBackground))
        .overlay(alignment: .trailing) {
            if !isEditingPath {
                Button(action: beginEditingPath) {
                    ThemeGlyph(ThemeIconNames.editPath, symbol: "pencil", size: 11)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Edit Path")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(theme.separator, lineWidth: 1))
    }

    private func breadcrumb(_ component: AppPathComponent) -> some View {
        let isCurrent = component.path == model.path
        return HStack(spacing: 1) {
            if component.path != "/" {
                Image(systemName: "chevron.compact.right")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            Button {
                model.navigate(to: component.path)
            } label: {
                Group {
                    if component.path == "/" {
                        ThemeGlyph(ThemeIconNames.rootDrive, symbol: "internaldrive", size: 13)
                    } else {
                        Text(component.name)
                    }
                }
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? theme.primaryText : theme.secondaryText)
                .padding(.horizontal, 5)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(model.dropTarget == component.path && !isCurrent
                                                                   ? theme.accent.opacity(0.4) : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .onDrop(of: DragItemProviders.acceptedTypes, delegate: dropDelegate(for: component.path))
        }
    }

    private var optionsMenu: some View {
        Menu {
            sortAndViewItems
        } label: {
            ThemeGlyph(ThemeIconNames.menu, symbol: "line.3.horizontal.decrease.circle", size: 14)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("View Options")
    }

    @ViewBuilder
    private var sortAndViewItems: some View {
        Menu {
            Picker("Sort By", selection: $model.sortKey) {
                ForEach(FilesSortKey.allCases) { key in
                    Text(key.rawValue).tag(key)
                }
            }
            Toggle("Ascending", isOn: $model.ascending)
        } label: {
            Label("Sort By", systemImage: "arrow.up.arrow.down")
        }
        Menu {
            Picker("View", selection: $model.viewMode) {
                Label("Icons", systemImage: "square.grid.2x2").tag(FilesViewMode.grid)
                Label("List", systemImage: "list.bullet").tag(FilesViewMode.list)
            }
        } label: {
            Label("View", systemImage: "rectangle.grid.1x2")
        }
        Toggle(isOn: $model.showHidden) {
            Label("Show Hidden Files", systemImage: "eye")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PLACES")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ForEach(model.places) { place in
                placeRow(place)
            }
            sectionTitle("IPAD")
            photosRow
            let mounted = model.mountedIPadPoints
            ForEach(IPadPlaceStore.shared.places) { place in
                iPadRow(place, available: mounted.contains(place.mountPoint))
            }
            if model.canMountIPadFolders {
                Button { model.addIPadFolder() } label: {
                    Label("Add iPad Folder…", systemImage: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityIdentifier("files.add-ipad-folder")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: 168)
        .background(theme.panelBackground)
        .transition(.move(edge: .leading))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func sidebarLabel(_ title: String, symbol: String, icon: [String], isCurrent: Bool,
                              dimmed: Bool = false) -> some View {
        Label { Text(title) } icon: { ThemeGlyph(icon, symbol: symbol, size: 15) }
            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(theme.primaryText.opacity(dimmed ? 0.45 : (isCurrent ? 1 : 0.85)))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? theme.accent.opacity(0.22) : Color.clear))
            .contentShape(Rectangle())
    }

    private var photosRow: some View {
        Button { showsPhotos = true } label: {
            sidebarLabel("Photos", symbol: "photo.on.rectangle", icon: ThemeIconNames.pictures, isCurrent: showsPhotos)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("files.place.Photos")
    }

    private func iPadRow(_ place: IPadPlace, available: Bool) -> some View {
        let isCurrent = !showsPhotos && model.path == place.mountPoint
        return Button {
            if available {
                showsPhotos = false
                model.navigate(to: place.mountPoint)
            } else {
                model.reconnect(place)
            }
        } label: {
            sidebarLabel(place.name, symbol: available ? "externaldrive" : "externaldrive.badge.exclamationmark",
                         icon: ThemeIconNames.iPadFolder, isCurrent: isCurrent, dimmed: !available)
                .overlay(alignment: .trailing) {
                    if available {
                        Button { model.eject(place) } label: {
                            ThemeGlyph(ThemeIconNames.eject, symbol: "eject", size: 11)
                                .font(.system(size: 11)).foregroundStyle(theme.secondaryText)
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Eject \(place.name)")
                    }
                }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .onDrop(of: DragItemProviders.acceptedTypes, delegate: dropDelegate(for: place.mountPoint))
        .contextMenu {
            if available {
                Button { model.openInNewWindow(place.mountPoint) } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
                Button { model.openTerminal(at: place.mountPoint) } label: { Label("Open Terminal Here", systemImage: "terminal") }
                Divider()
                Button { model.eject(place) } label: { Label("Eject", systemImage: "eject") }
            } else {
                Button { model.reconnect(place) } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive) { model.eject(place) } label: { Label("Remove from Sidebar", systemImage: "minus.circle") }
        }
        .accessibilityIdentifier("files.place.ipad.\(place.name)")
    }

    private func placeRow(_ place: FilesPlace) -> some View {
        let isCurrent = !showsPhotos && model.path == place.path
        let isDropTarget = model.dropTarget == place.path && !isCurrent
        return Button {
            showsPhotos = false
            model.navigate(to: place.path)
        } label: {
            Label { Text(place.name) } icon: { ThemeGlyph(place.iconNames, symbol: place.symbol, size: 15) }
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? theme.primaryText : theme.primaryText.opacity(0.85))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isDropTarget ? theme.accent.opacity(0.45) : (isCurrent ? theme.accent.opacity(0.22) : Color.clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("files.place.\(place.name)")
        .onDrop(of: DragItemProviders.acceptedTypes, delegate: dropDelegate(for: place.path))
        .contextMenu {
            Button { model.openInNewWindow(place.path) } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
            Button { model.openTerminal(at: place.path) } label: {
                Label("Open Terminal Here", systemImage: "terminal")
            }
            if place.path == model.trash.filesDirectory {
                Divider()
                Button(role: .destructive) { confirmsEmptyTrash = true } label: {
                    Label("Empty Trash…", systemImage: "trash.slash")
                }
            }
        }
    }

    // MARK: Content

    private var content: some View {
        let items = model.visibleEntries
        return ZStack(alignment: .bottom) {
            Group {
                if items.isEmpty {
                    if model.isLoading {
                        ProgressView().controlSize(.large)
                    } else if model.errorMessage == nil {
                        AppEmptyState(symbol: model.isTrash ? "trash" : "folder",
                                      title: model.isTrash ? "Trash is empty" : "Folder is empty",
                                      message: model.hiddenCount > 0 && !model.showHidden && !model.isTrash
                                          ? "\(model.hiddenCount) hidden item(s). Use View Options to show them."
                                          : nil)
                    } else {
                        AppEmptyState(symbol: "exclamationmark.triangle", title: "Can't show this folder")
                    }
                } else if model.viewMode == .list {
                    listView(items)
                } else {
                    gridView(items)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isPreparingPreview {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("files.preview-spinner")
            }
            if let target = model.dropTarget, let operation = model.dropOperation {
                DropBadge(directory: target == model.trash.filesDirectory ? "Trash" : target, operation: operation)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // A click on empty space clears the selection and gives the list the keyboard.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selection = []
                    keyFocusToken += 1
                }
        }
        .overlay {
            if model.dropTarget == model.path {
                RoundedRectangle(cornerRadius: 6).stroke(theme.accent, lineWidth: 2).padding(2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: DragItemProviders.acceptedTypes, delegate: dropDelegate(for: model.path))
        .contextMenu { backgroundMenu }
        .accessibilityIdentifier("files.content")
    }

    private func dropDelegate(for directory: String) -> FolderDropDelegate {
        FolderDropDelegate(directory: directory) { target, operation in
            model.setDropTarget(target, operation)
        } onDrop: { providers, operation in
            model.drop(providers, into: directory, operation: operation)
        }
    }

    private func listView(_ items: [FileEntry]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                        listRow(entry, striped: index.isMultiple(of: 2))
                    }
                } header: {
                    listHeader
                }
            }
        }
    }

    private var listHeader: some View {
        HStack(spacing: 10) {
            sortHeader(.name)
                .padding(.leading, 30)
            sortHeader(.size, alignment: .trailing)
                .frame(width: 84)
            if model.isTrash {
                Text("Original Location")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 180, alignment: .leading)
            } else {
                sortHeader(.modified)
                    .frame(width: 150)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(theme.titleBarInactive.opacity(0.96))
        .overlay(alignment: .bottom) { ThemedSeparator() }
    }

    private func sortHeader(_ key: FilesSortKey, alignment: Alignment = .leading) -> some View {
        SortableHeader(title: key.rawValue, isActive: model.sortKey == key, ascending: model.ascending,
                       alignment: alignment) {
            if model.sortKey == key {
                model.ascending.toggle()
            } else {
                model.sortKey = key
                model.ascending = key == .name || key == .kind
            }
        }
    }

    private func rowBackground(_ entry: FileEntry, striped: Bool) -> Color {
        if model.dropTarget == entry.path { return theme.accent.opacity(0.45) }
        if model.selection.contains(entry.path) { return theme.accent.opacity(0.28) }
        return striped ? theme.primaryText.opacity(0.025) : Color.clear
    }

    private func listRow(_ entry: FileEntry, striped: Bool) -> some View {
        HStack(spacing: 10) {
            FileIconView(entry: entry, size: 14, theme: theme, home: model.homeDirectory)
                .frame(width: 20)
            Text(entry.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(entry.name.hasPrefix(".") ? 0.65 : 1)
            if entry.isSymlink {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 8)
            Text(entry.isDirectory ? "—" : ByteFormat.string(entry.size))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .frame(width: 84, alignment: .trailing)
            Group {
                if model.isTrash {
                    Text(model.trashItems[entry.name].map { AppPath.parent(of: $0.originalPath) } ?? "—")
                        .truncationMode(.head)
                } else if let modified = entry.modified {
                    Text(modified, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                } else {
                    Text("—")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.secondaryText)
            .lineLimit(1)
            .frame(width: model.isTrash ? 180 : 150, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(rowBackground(entry, striped: striped))
        .opacity(clipboard.isCut(entry.path) ? 0.5 : 1)
        .contentShape(Rectangle())
        .modifier(entryInteractions(entry))
    }

    private func entryInteractions(_ entry: FileEntry) -> EntryInteractions<AnyView> {
        EntryInteractions(entry: entry, model: model,
                          dropDelegate: entry.isDirectory && !model.isTrash ? dropDelegate(for: entry.path) : nil,
                          focus: { keyFocusToken += 1 },
                          menu: { AnyView(itemMenu(entry)) })
    }

    private func gridView(_ items: [FileEntry]) -> some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)], spacing: 10) {
                    ForEach(items) { entry in
                        gridCell(entry)
                    }
                }
                .padding(12)
            }
            .onAppear { model.gridColumns = Self.columns(for: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in model.gridColumns = Self.columns(for: width) }
        }
    }

    /// LazyVGrid's adaptive layout: 96 pt minimum cells, 8 pt spacing, 12 pt padding.
    private static func columns(for width: CGFloat) -> Int {
        max(1, Int((width - 24 + 8) / (96 + 8)))
    }

    private func gridCell(_ entry: FileEntry) -> some View {
        let isSelected = model.selection.contains(entry.path)
        let isDropTarget = model.dropTarget == entry.path
        return VStack(spacing: 6) {
            FileIconView(entry: entry, size: 34, theme: theme, home: model.homeDirectory)
                .frame(height: 40)
            Text(entry.name)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? theme.accent.readableLabel : theme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(isSelected ? theme.accent.opacity(0.85) : Color.clear))
                .opacity(entry.name.hasPrefix(".") ? 0.65 : 1)
        }
        .frame(width: 100, height: 92)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? theme.accent.opacity(0.4) : (isSelected ? theme.accent.opacity(0.15) : Color.clear)))
        .opacity(clipboard.isCut(entry.path) ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .modifier(entryInteractions(entry))
    }

    // MARK: Menus

    @ViewBuilder
    private func itemMenu(_ entry: FileEntry) -> some View {
        let targets = model.targets(for: entry)
        let single = targets.count == 1 ? targets.first : nil
        if model.isTrash {
            Button { model.restore(targets) } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) { pendingDeletion = targets } label: {
                Label("Delete Permanently…", systemImage: "trash.slash")
            }
            Divider()
            Button { propertiesTarget = PropertiesTarget(path: entry.path) } label: {
                Label("Properties", systemImage: "info.circle")
            }
        } else {
            Button {
                if let single { model.open(single) } else { model.openSelection() }
            } label: {
                Label("Open", systemImage: entry.isDirectory ? "folder" : "arrow.up.forward.app")
            }
            if let single {
                openWithMenu(single)
                if single.isDirectory {
                    Button { model.openInNewWindow(single.path) } label: {
                        Label("Open in New Window", systemImage: "macwindow.badge.plus")
                    }
                }
            }
            Button { model.openTerminal(at: single?.isDirectory == true ? entry.path : model.path) } label: {
                Label("Open Terminal Here", systemImage: "terminal")
            }
            Divider()
            Button { model.cut(targets) } label: { Label("Cut", systemImage: "scissors") }
            Button { model.copy(targets) } label: { Label("Copy", systemImage: "doc.on.doc") }
            if let single, single.isDirectory, !clipboard.isEmpty {
                Button { model.paste(into: single.path) } label: {
                    Label("Paste Into Folder", systemImage: "doc.on.clipboard")
                }
            }
            Button { model.copyPaths(targets) } label: { Label("Copy Path", systemImage: "link") }
            Divider()
            if let single {
                Button { beginPrompt(.rename(single), text: single.name) } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            }
            Button { model.duplicate(targets) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Menu {
                Button("tar.gz") { model.compress(targets, format: .tarGz) }
                if model.canCreateZip {
                    Button("zip") { model.compress(targets, format: .zip) }
                }
            } label: {
                Label("Compress", systemImage: "archivebox")
            }
            if let single, !single.isDirectory, FileOperations.isArchive(single.name) {
                Button { model.extractHere(single) } label: {
                    Label("Extract Here", systemImage: "archivebox.circle")
                }
            }
            Divider()
            if targets.contains(where: { !$0.isDirectory }) {
                Button { model.quickLook(targets) } label: { Label("Quick Look", systemImage: "eye") }
            }
            Button { model.share(targets) } label: { Label("Share…", systemImage: "square.and.arrow.up") }
            if targets.contains(where: { !$0.isDirectory && PhotosSaver.canSave($0.name) }) {
                Button { model.saveToPhotos(targets) } label: { Label("Save to Photos", systemImage: "photo.badge.plus") }
            }
            Divider()
            Button(role: .destructive) { model.moveToTrash(targets) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            Button(role: .destructive) { pendingDeletion = targets } label: {
                Label("Delete Permanently…", systemImage: "trash.slash")
            }
            Divider()
            Button { propertiesTarget = PropertiesTarget(path: entry.path) } label: {
                Label("Properties", systemImage: "info.circle")
            }
        }
    }

    @ViewBuilder
    private func openWithMenu(_ entry: FileEntry) -> some View {
        let catalog = OpenWithCatalog.shared
        let mime = catalog.mimeType(for: entry.name, isDirectory: entry.isDirectory)
        let linuxApps = catalog.linuxApplications(for: mime)
        Menu {
            if entry.isDirectory {
                Button { model.openInNewWindow(entry.path) } label: { Label("Files", systemImage: "folder") }
            } else {
                Button { model.openInEditor(entry.path) } label: { Label("Text Editor", systemImage: "doc.text") }
                Button { model.quickLook([entry]) } label: { Label("Quick Look", systemImage: "eye") }
            }
            if !linuxApps.isEmpty {
                Section("Linux Applications") {
                    ForEach(linuxApps) { app in
                        Button(app.name) { model.open(entry, with: app) }
                    }
                }
            }
        } label: {
            Label("Open With", systemImage: "arrow.up.right.square")
        }
    }

    @ViewBuilder
    private var backgroundMenu: some View {
        if model.isTrash {
            Button(role: .destructive) { confirmsEmptyTrash = true } label: {
                Label("Empty Trash…", systemImage: "trash.slash")
            }
            .disabled(model.entries.isEmpty)
        } else {
            Menu {
                Button { beginPrompt(.newFolder, text: "New Folder") } label: {
                    Label("Folder", systemImage: "folder.badge.plus")
                }
                Button { beginPrompt(.newFile, text: "untitled.txt") } label: {
                    Label("Text File", systemImage: "doc.badge.plus")
                }
            } label: {
                Label("Create New", systemImage: "plus")
            }
            Button { beginPrompt(.newFolder, text: "New Folder") } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Button { beginPrompt(.newFile, text: "untitled.txt") } label: {
                Label("New File", systemImage: "doc.badge.plus")
            }
            Button { model.paste() } label: {
                Label(clipboard.paths.count > 1 ? "Paste \(clipboard.paths.count) Items" : "Paste", systemImage: "doc.on.clipboard")
            }
            .disabled(clipboard.isEmpty)
            Divider()
            Button { model.openTerminal(at: model.path) } label: {
                Label("Open Terminal Here", systemImage: "terminal")
            }
        }
        Button { model.selectAll() } label: {
            Label("Select All", systemImage: "checkmark.circle")
        }
        Divider()
        sortAndViewItems
        Button { model.reload() } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        if !model.isTrash {
            Button { propertiesTarget = PropertiesTarget(path: model.path) } label: {
                Label("Properties", systemImage: "info.circle")
            }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        AppStatusBar {
            let count = model.visibleEntries.count
            Text("\(count) item\(count == 1 ? "" : "s")")
            if !model.selectedEntries.isEmpty {
                let selected = model.selectedEntries
                let bytes = selected.filter { !$0.isDirectory }.reduce(Int64(0)) { $0 + $1.size }
                Text("\(selected.count) selected" + (bytes > 0 ? " (\(ByteFormat.string(bytes)))" : ""))
            }
            if !model.showHidden && model.hiddenCount > 0 && !model.isTrash {
                Text("\(model.hiddenCount) hidden")
            }
            if let activity = model.activity {
                HStack(spacing: 6) {
                    Text(activity.title + "…")
                    if activity.total > 0 {
                        ProgressView(value: activity.fraction)
                            .frame(width: 90)
                        Text(ByteFormat.string(activity.completed) + " of " + ByteFormat.string(activity.total))
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .accessibilityIdentifier("files.activity")
            } else if model.isLoading && !model.entries.isEmpty {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 0)
            Text(model.path)
                .font(.caption.monospaced())
                .truncationMode(.head)
        }
    }

    // MARK: Prompts

    private var isPromptPresented: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private var isDeletionPresented: Binding<Bool> {
        Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1 ? "Permanently delete “\(pendingDeletion[0].name)”?"
                                   : "Permanently delete \(pendingDeletion.count) items?"
    }

    private func beginPrompt(_ newPrompt: FilesPrompt, text: String) {
        promptText = text
        prompt = newPrompt
    }

    private func beginEditingPath() {
        pathDraft = model.path
        isEditingPath = true
        pathFieldFocused = true
    }

    private func commit(_ prompt: FilesPrompt) {
        switch prompt {
        case .newFolder: model.createFolder(named: promptText)
        case .newFile: model.createFile(named: promptText)
        case .rename(let entry): model.rename(entry, to: promptText)
        }
    }
}

/// Click and double-click, dragging out, dropping onto folders and the context menu,
/// shared by list rows and icons.
struct EntryInteractions<MenuContent: View>: ViewModifier {
    let entry: FileEntry
    let model: FilesModel
    let dropDelegate: FolderDropDelegate?
    let focus: () -> Void
    let menu: () -> MenuContent

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { model.open(entry) }
            .simultaneousGesture(TapGesture().onEnded {
                model.click(entry)
                focus()
            })
            .hoverEffect(.highlight)
            .onDrag { model.dragProvider(for: entry) }
            .modifier(OptionalDrop(delegate: dropDelegate))
            .contextMenu { menu() }
            .accessibilityIdentifier("files.entry.\(entry.name)")
    }
}

struct OptionalDrop: ViewModifier {
    let delegate: FolderDropDelegate?

    func body(content: Content) -> some View {
        if let delegate {
            content.onDrop(of: DragItemProviders.acceptedTypes, delegate: delegate)
        } else {
            content
        }
    }
}

#Preview("Files") {
    FilesAppView(context: AppsPreview.context([AppArgument.path: "/root/app"]))
        .frame(width: 840, height: 540)
}

/// A file's icon from the style's icon pack (by MIME type, FileTypeIcons), or its SF Symbol.
struct FileIconView: View {
    let entry: FileEntry
    let size: CGFloat
    let theme: DesktopTheme
    /// The home directory, whose Desktop, Documents, … folders have their own icons.
    var home: String? = nil
    @Environment(\.desktopIcons) private var icons

    var body: some View {
        if let image = icons?.icon(FileTypeIcons.iconNames(for: entry, home: home))?.image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 1.3, height: size * 1.3)
        } else {
            Image(systemName: FileIcon.symbol(for: entry))
                .font(.system(size: size))
                .foregroundStyle(FileIcon.tint(for: entry, theme: theme))
        }
    }
}
