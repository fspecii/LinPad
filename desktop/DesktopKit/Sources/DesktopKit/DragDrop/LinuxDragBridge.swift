import Foundation
import UIKit
import UniformTypeIdentifiers
import os

/// Host half of drag and drop with Linux apps (wl-bridge/DND-SPEC.md).
///
/// Drags that start in a Linux app are Wayland drags inside ishwl. Their touch stays with
/// the source window's LinuxSurfaceView, so a passive recognizer on every Linux view follows
/// it and tells ishwl what is under it (`dnd_over`): another Linux view, which ishwl serves
/// itself, or native UI, in which case ishwl hands the data over (`dnd_data`) when the
/// button is released and the host performs the drop. iOS can't turn a touch that is
/// already in progress into a system drag session, so these drags stay inside this app.
///
/// Drags from native windows and other iPadOS apps reach Linux windows through a
/// UIDropInteraction on each Linux view, which drives a host-side drag in ishwl
/// (`dnd_enter`/`dnd_motion`/`dnd_drop`); files are copied into the guest first.
@MainActor
final class LinuxDragBridge: NSObject, UIDropInteractionDelegate {
    private static let logger = Logger(subsystem: "DesktopKit", category: "LinuxDnD")
    static let stagingDirectory = "/tmp/ishwl-dnd"

    private weak var center: DragDropCenter?
    private let host: any LinuxGraphicsHost
    private var eventsFD: Int32 = -1
    private var reader: DragFIFOReader?
    private var connectedInode: ino_t = 0
    private let watchedViews = NSHashTable<UIView>.weakObjects()

    /// A Wayland drag that a Linux app started.
    private struct LinuxDrag {
        var mimeTypes: [String]
        var lastTarget: String = ""
        var dropPoint: CGPoint?
    }

    private var linuxDrag: LinuxDrag?
    var isLinuxDragActive: Bool { linuxDrag != nil }
    /// Every message from ishwl's dnd FIFO, for the debug automation log.
    var onMessage: ((String) -> Void)?
    private var dragToken: DragTokenView?

    /// Host drag over a Linux view and ishwl's latest answer for it.
    private var hostDrag: HostDrag?
    private var dataPublished = false
    private var targetAccepts = true
    private var targetAction = 1

    init(center: DragDropCenter, host: any LinuxGraphicsHost) {
        self.center = center
        self.host = host
        super.init()
    }

    private var runtimeURL: URL? {
        host.guestRootURL?.appendingPathComponent(String(LinuxGUIBridge.guestRuntimeDirectory.dropFirst()), isDirectory: true)
    }

    // MARK: - Connection

    /// ishwl creates the `dnd` FIFO only when it supports drag and drop; a new session
    /// recreates both FIFOs, which the inode check notices.
    private func connectIfNeeded() -> Bool {
        guard let runtimeURL else { return false }
        let dndPath = runtimeURL.appendingPathComponent("dnd").path
        let eventsPath = runtimeURL.appendingPathComponent("events").path
        var info = stat()
        guard stat(dndPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFIFO else {
            disconnect()
            return false
        }
        if info.st_ino == connectedInode, eventsFD >= 0 { return true }
        disconnect()
        let notifyFD = open(dndPath, O_RDWR | O_CLOEXEC)
        // ishwl holds the events FIFO open for reading, so a non-blocking writer opens at once.
        let writer = open(eventsPath, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        guard notifyFD >= 0, writer >= 0 else {
            if notifyFD >= 0 { close(notifyFD) }
            if writer >= 0 { close(writer) }
            return false
        }
        eventsFD = writer
        connectedInode = info.st_ino
        reader = DragFIFOReader(fd: notifyFD) { [weak self] lines in
            Task { @MainActor in
                for line in lines { self?.handle(line) }
            }
        }
        return true
    }

    private func disconnect() {
        reader?.stop()
        reader = nil
        if eventsFD >= 0 { close(eventsFD) }
        eventsFD = -1
        connectedInode = 0
        endLinuxDrag()
    }

    var isAvailable: Bool { connectIfNeeded() }

    private func send(_ line: String) {
        guard eventsFD >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        let written = bytes.withUnsafeBytes { write(eventsFD, $0.baseAddress, $0.count) }
        if written != bytes.count {
            Self.logger.error("dropped dnd message '\(line, privacy: .public)'")
        }
    }

    // MARK: - Linux views

    func attachToLinuxViews() {
        guard let controller = center?.controller, let linux = controller.linux, connectIfNeeded() else { return }
        for id in controller.linuxWindows.keys {
            guard let view = linux.surface(withID: id)?.view, !watchedViews.contains(view) else { continue }
            watchedViews.add(view)
            let observer = LinuxDragTouchObserver()
            observer.onMove = { [weak self, weak view] location in
                guard let self, let view else { return }
                self.linuxDragMoved(to: location, in: view)
            }
            observer.onEnd = { [weak self, weak view] location in
                guard let self, let view else { return }
                self.linuxDragEnded(at: location, in: view)
            }
            observer.onCancel = { [weak self] in self?.linuxDragCancelled() }
            view.addGestureRecognizer(observer)
            view.addInteraction(UIDropInteraction(delegate: self))
        }
    }

    // MARK: - Drags from Linux apps

    private func handle(_ line: String) {
        onMessage?(line)
        let fields = line.split(separator: " ").map(String.init)
        guard let command = fields.first else { return }
        switch command {
        case "dnd_start":
            let mimes = fields.count > 1 ? LinuxGUIBridge.unescape(fields[1]).split(separator: ",").map(String.init) : []
            linuxDrag = LinuxDrag(mimeTypes: mimes)
            showToken(for: mimes)
        case "dnd_status":
            targetAccepts = fields.count > 1 && fields[1] == "1"
            targetAction = fields.count > 2 ? Int(fields[2]) ?? 1 : 1
        case "dnd_data":
            guard fields.count > 2 else { return }
            receiveData(mime: LinuxGUIBridge.unescape(fields[1]), file: LinuxGUIBridge.unescape(fields[2]))
        case "dnd_end":
            endLinuxDrag()
            NotificationCenter.default.post(name: .guestFilesChanged, object: nil)
        case "dnd_done":
            NotificationCenter.default.post(name: .guestFilesChanged, object: nil)
        default:
            Self.logger.debug("unknown dnd message \(line, privacy: .public)")
        }
    }

    func linuxDragMoved(to location: CGPoint, in sourceView: UIView) {
        guard linuxDrag != nil, let window = sourceView.window else { return }
        let point = sourceView.convert(location, to: window)
        dragToken?.move(to: point)
        report(point, in: window)
    }

    /// Tells ishwl what is under the touch; repeated native positions are coalesced.
    private func report(_ point: CGPoint, in window: UIWindow) {
        if let (surface, local) = linuxView(at: point, in: window) {
            send("dnd_over \(surface.surfaceID) \(Self.format(local.x)) \(Self.format(local.y))")
            linuxDrag?.lastTarget = "linux"
            dragToken?.setAccepted(true)
            return
        }
        let accepts = center?.nativeHandler(atWindowPoint: point) != nil
        let target = accepts ? "native" : "none"
        dragToken?.setAccepted(accepts)
        guard linuxDrag?.lastTarget != target else { return }
        linuxDrag?.lastTarget = target
        send("dnd_over 0 \(accepts ? 1 : 0)")
    }

    /// Runs before LinuxSurfaceView sends the button release (recognizers see touches
    /// first), so ishwl has the final target when the release ends its drag.
    func linuxDragEnded(at location: CGPoint, in sourceView: UIView) {
        guard linuxDrag != nil, let window = sourceView.window else { return }
        let point = sourceView.convert(location, to: window)
        linuxDrag?.lastTarget = ""
        report(point, in: window)
        linuxDrag?.dropPoint = point
    }

    private func linuxDragCancelled() {
        guard linuxDrag != nil else { return }
        send("dnd_cancel")
        endLinuxDrag()
    }

    private func endLinuxDrag() {
        linuxDrag = nil
        dragToken?.removeFromSuperview()
        dragToken = nil
    }

    private func receiveData(mime: String, file: String) {
        let point = linuxDrag?.dropPoint
        guard let runtimeURL, let point,
              let handler = center?.nativeHandler(atWindowPoint: point),
              let data = try? Data(contentsOf: runtimeURL.appendingPathComponent(file)) else { return }
        let items = Self.items(fromData: data, mime: mime)
        guard !items.isEmpty else { return }
        handler(items, items.contains { $0.guestPath != nil } ? DropOperation.forGuestDrag() : .copy)
    }

    static func items(fromData data: Data, mime: String) -> [DragItem] {
        let text = String(decoding: data, as: UTF8.self)
        switch mime {
        case "text/uri-list":
            return URIList.parse(text).map { uri in
                if let path = URIList.guestPath(fromFileURI: uri) {
                    return .guestFile(path: path, isDirectory: false)
                }
                return URL(string: uri).map(DragItem.url) ?? .text(uri)
            }
        case "image/png":
            return [.data(data, suggestedName: "Dropped Image.png")]
        default:
            return text.isEmpty ? [] : [.text(text)]
        }
    }

    private func linuxView(at point: CGPoint, in window: UIWindow) -> (LinuxSurfaceView, CGPoint)? {
        var view = window.hitTest(point, with: nil)
        while let current = view {
            if let surface = current as? LinuxSurfaceView {
                return (surface, surface.convert(point, from: window))
            }
            view = current.superview
        }
        return nil
    }

    private func showToken(for mimes: [String]) {
        dragToken?.removeFromSuperview()
        guard let window = center?.controller?.input.referenceView?.window else { return }
        let token = DragTokenView(isFile: mimes.contains("text/uri-list"))
        window.addSubview(token)
        dragToken = token
    }

    // MARK: - Drops onto Linux windows

    /// A host drag over a Linux view. Imported files get their guest paths up front, so
    /// the URI list a client reads while hovering (Thunar does) matches the files that
    /// exist after the drop.
    private struct HostDrag {
        let surfaceID: UInt32
        let directory: String
        let kind: ContentKind
        let plannedNames: [String?]
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        connectIfNeeded() && session.items.contains { !$0.itemProvider.registeredTypeIdentifiers.isEmpty }
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let view = interaction.view as? LinuxSurfaceView else { return UIDropProposal(operation: .forbidden) }
        let point = session.location(in: view)
        let isLocal = session.localDragSession != nil
        let earlyData = isLocal || Self.contentKind(of: session.items.map(\.itemProvider)) == .files
        if hostDrag?.surfaceID != view.surfaceID {
            if hostDrag != nil { send("dnd_leave") }
            let providers = session.items.map(\.itemProvider)
            let drag = HostDrag(surfaceID: view.surfaceID,
                                directory: AppPath.join(Self.stagingDirectory, UUID().uuidString),
                                kind: Self.contentKind(of: providers),
                                plannedNames: Self.plannedNames(for: providers))
            hostDrag = drag
            targetAccepts = true
            targetAction = 1
            // Guest files dragged from a native window may be moved, like a drag between
            // file managers; anything from outside the guest can only be copied.
            let actions = drag.kind == .guestFiles ? 3 : 1
            let preferred = drag.kind == .guestFiles && DropOperation.forGuestDrag() == .move ? 2 : 1
            let mimes = LinuxGUIBridge.escape(drag.kind.mimeTypes.joined(separator: ","))
            send("dnd_enter \(view.surfaceID) \(Self.format(point.x)) \(Self.format(point.y)) \(actions) \(preferred) \(mimes)")
            Task { await publishEarlyData(drag, providers: providers) }
            dataPublished = false
        } else {
            send("dnd_motion \(view.surfaceID) \(Self.format(point.x)) \(Self.format(point.y))")
        }
        // Clients decline until they have read the data; only a refusal after that counts.
        if !targetAccepts && dataPublished && earlyData { return UIDropProposal(operation: .forbidden) }
        return UIDropProposal(operation: isLocal && targetAction == 2 ? .move : .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        leaveHostDrag()
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        leaveHostDrag()
    }

    private func leaveHostDrag() {
        guard hostDrag != nil else { return }
        hostDrag = nil
        send("dnd_leave")
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let view = interaction.view as? LinuxSurfaceView, let drag = hostDrag else { return }
        let point = session.location(in: view)
        // The drop is answered once the data is in the guest, which can take a moment
        // for large files; ishwl keeps the offer entered until then.
        hostDrag = nil
        let providers = session.items.map(\.itemProvider)
        Task {
            do {
                let manifest = try await prepareDrop(drag, providers: providers)
                send("dnd_data_ready \(LinuxGUIBridge.escape(manifest))")
                send("dnd_drop \(drag.surfaceID) \(Self.format(point.x)) \(Self.format(point.y))")
            } catch {
                send("dnd_leave")
                center?.notify("Couldn't drop: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Drop data

    enum ContentKind: Equatable {
        case guestFiles, files, url, text

        var mimeTypes: [String] {
            switch self {
            case .guestFiles, .files: return ["text/uri-list"]
            case .url: return ["text/uri-list", "text/plain;charset=utf-8", "UTF8_STRING", "text/plain"]
            case .text: return ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain"]
            }
        }
    }

    static func contentKind(of providers: [NSItemProvider]) -> ContentKind {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.guestItems.identifier) }) {
            return .guestFiles
        }
        let types = providers.flatMap(\.registeredTypeIdentifiers).compactMap(UTType.init)
        if types.contains(where: isFileType) { return .files }
        if types.contains(where: { $0.conforms(to: .url) }) { return .url }
        return .text
    }

    private static func isFileType(_ type: UTType) -> Bool {
        type.conforms(to: .fileURL) || type.conforms(to: .image) || type.conforms(to: .movie)
            || type.conforms(to: .audio) || type.conforms(to: .pdf) || type.conforms(to: .folder)
            || (type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url))
    }

    /// The file name each external file will get in the staging folder, unique within it.
    static func plannedNames(for providers: [NSItemProvider]) -> [String?] {
        var taken = Set<String>()
        return providers.map { provider in
            guard let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: isFileType) else {
                return nil
            }
            var name = provider.suggestedName ?? "Dropped Item"
            if let ext = type.preferredFilenameExtension, AppPath.pathExtension(name).isEmpty {
                name += "." + ext
            }
            name = FileNaming.unique(name.replacingOccurrences(of: "/", with: "-"), existing: taken)
            taken.insert(name)
            return name
        }
    }

    private func filesDirectory(_ drag: HostDrag) -> String { AppPath.join(drag.directory, "files") }

    /// Publishes the URI list before the drop for file drags; text arrives with the drop.
    private func publishEarlyData(_ drag: HostDrag, providers: [NSItemProvider]) async {
        var uris: [String] = []
        switch drag.kind {
        case .guestFiles:
            uris = DragItemProviders.lastGuestPayload?.paths.map(URIList.fileURI(forGuestPath:)) ?? []
        case .files:
            uris = drag.plannedNames.compactMap { $0 }.map { URIList.fileURI(forGuestPath: AppPath.join(filesDirectory(drag), $0)) }
        case .url, .text:
            return
        }
        guard !uris.isEmpty, let manifest = try? await writeManifest(drag, uris: uris, texts: []) else { return }
        guard hostDrag?.directory == drag.directory else { return }
        send("dnd_data_ready \(LinuxGUIBridge.escape(manifest))")
        try? await Task.sleep(for: .seconds(1))
        if hostDrag?.directory == drag.directory { dataPublished = true }
    }

    /// Copies what is needed into the guest and writes the manifest ishwl reads:
    /// one "MIME<TAB>GUEST-PATH" line per offered type.
    private func prepareDrop(_ drag: HostDrag, providers: [NSItemProvider]) async throws -> String {
        guard let transfer = center?.transfer else { throw LinuxHostError.invalidPath(Self.stagingDirectory) }
        var uris: [String] = []
        var texts: [String] = []
        for (index, provider) in providers.enumerated() {
            let (_, items) = await DragItemProviders.loadItems(from: [provider])
            let planned = index < drag.plannedNames.count ? drag.plannedNames[index] : nil
            for item in items {
                switch item {
                case .guestFile(let path, _):
                    uris.append(URIList.fileURI(forGuestPath: path))
                case .hostFile(let url):
                    try await ensureDirectory(filesDirectory(drag))
                    let path = try await transfer.importItem(at: url, into: filesDirectory(drag), name: planned)
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    uris.append(URIList.fileURI(forGuestPath: path))
                case .data(let data, let name):
                    try await ensureDirectory(filesDirectory(drag))
                    let path = try await transfer.importData(data, named: planned ?? name, into: filesDirectory(drag))
                    uris.append(URIList.fileURI(forGuestPath: path))
                case .url(let url):
                    uris.append(url.absoluteString)
                    texts.append(url.absoluteString)
                case .text(let text):
                    texts.append(text)
                }
            }
        }
        return try await writeManifest(drag, uris: uris, texts: texts)
    }

    private func ensureDirectory(_ path: String) async throws {
        let result = await host.run("mkdir -p -- \(path.shellQuoted)", cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
    }

    private func writeManifest(_ drag: HostDrag, uris: [String], texts: [String]) async throws -> String {
        let setup = await host.run("""
            find \(Self.stagingDirectory) -mindepth 1 -maxdepth 1 -mmin +60 -exec rm -rf {} + 2>/dev/null
            mkdir -p -- \(drag.directory.shellQuoted)
            """, cwd: nil, stdin: nil)
        guard setup.succeeded else { throw LinuxHostError.commandFailed(setup) }
        var manifest = ""
        if !uris.isEmpty {
            let path = AppPath.join(drag.directory, "uri-list")
            try await host.writeFile(path, data: Data(URIList.format(uris).utf8))
            manifest += "text/uri-list\t\(path)\n"
        }
        if !texts.isEmpty {
            let path = AppPath.join(drag.directory, "text")
            try await host.writeFile(path, data: Data(texts.joined(separator: "\n").utf8))
            for mime in ContentKind.text.mimeTypes { manifest += "\(mime)\t\(path)\n" }
        }
        let manifestPath = AppPath.join(drag.directory, "manifest")
        try await host.writeFile(manifestPath, data: Data(manifest.utf8))
        return manifestPath
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}

/// text/uri-list (RFC 2483): CRLF-separated URIs, '#' comments, file URIs percent-encoded.
enum URIList {
    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func format(_ uris: [String]) -> String {
        uris.map { $0 + "\r\n" }.joined()
    }

    static func fileURI(forGuestPath path: String) -> String {
        "file://" + TrashInfo.encodePath(path)
    }

    /// "file:///root/a%20b" and "file://localhost/root/a%20b" → "/root/a b".
    static func guestPath(fromFileURI uri: String) -> String? {
        guard uri.lowercased().hasPrefix("file://") else { return nil }
        var rest = uri.dropFirst("file://".count)
        if !rest.hasPrefix("/") {
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            rest = rest[slash...]
        }
        return String(rest).removingPercentEncoding
    }
}

/// Follows a touch on a Linux view without taking part in gesture recognition: it never
/// recognizes and never cancels or delays the view's own touch handling.
final class LinuxDragTouchObserver: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onMove: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    private weak var trackedTouch: UITouch?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if trackedTouch == nil { trackedTouch = touches.first }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        onMove?(touch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        onEnd?(touch.location(in: view))
        trackedTouch = nil
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        onCancel?()
        trackedTouch = nil
        state = .failed
    }

    override func reset() {
        trackedTouch = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// What a Linux drag carries, following the touch (ishwl doesn't composite drag icons).
private final class DragTokenView: UIVisualEffectView {
    private let icon = UIImageView()

    init(isFile: Bool) {
        super.init(effect: UIBlurEffect(style: .systemThinMaterial))
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        layer.cornerRadius = 12
        clipsToBounds = true
        isUserInteractionEnabled = false
        icon.image = UIImage(systemName: isFile ? "doc.fill" : "text.alignleft")
        icon.tintColor = .label
        icon.contentMode = .center
        icon.frame = bounds
        contentView.addSubview(icon)
        accessibilityIdentifier = "dnd.linux-token"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func move(to point: CGPoint) {
        center = CGPoint(x: point.x + 26, y: point.y + 26)
    }

    func setAccepted(_ accepted: Bool) {
        alpha = accepted ? 1 : 0.55
    }
}

/// Line reader for the dnd FIFO on its own thread; the FIFO is open O_RDWR, so it never
/// sees EOF and polls with a timeout to notice `stop()`.
private final class DragFIFOReader: @unchecked Sendable {
    private let fd: Int32
    private let deliver: @Sendable ([String]) -> Void
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    init(fd: Int32, deliver: @escaping @Sendable ([String]) -> Void) {
        self.fd = fd
        self.deliver = deliver
        let thread = Thread { [self] in run() }
        thread.name = "LinuxDragBridge.dnd"
        thread.start()
    }

    func stop() {
        stopped.withLock { $0 = true }
    }

    private func run() {
        defer { close(fd) }
        var pending = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !stopped.withLock({ $0 }) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 500) > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[0..<count])
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let lines = pending[...lastNewline].split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
            pending.removeSubrange(...lastNewline)
            if !stopped.withLock({ $0 }) { deliver(lines) }
        }
    }
}
