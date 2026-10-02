import SwiftUI
import UIKit

/// Ties drag and drop together across the desktop. Native windows that take drops from
/// Linux apps register a handler here (SwiftUI drops reach them directly; drags that start
/// in a Linux app never become UIKit drag sessions, see LinuxDragBridge), and every native
/// app reaches the shared transfer service and the Linux bridge through it.
extension Notification.Name {
    /// Posted when a drop elsewhere (a Linux app, the desktop) may have moved or added
    /// guest files, so file views refresh without waiting for their next poll.
    static let guestFilesChanged = Notification.Name("DesktopKit.guestFilesChanged")
}

@MainActor
final class DragDropCenter {
    static let shared = DragDropCenter()

    typealias DropHandler = @MainActor (_ items: [DragItem], _ operation: DropOperation) -> Void

    private(set) weak var controller: DesktopController?
    private(set) var transfer: GuestTransferService?
    private(set) var linuxDrag: LinuxDragBridge?
    private var windowHandlers: [UUID: DropHandler] = [:]
    private var desktopHandler: DropHandler?

    /// Called once the desktop exists (from the desktop surface).
    func attach(_ controller: DesktopController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        transfer = GuestTransferService(host: controller.host)
        HostStaging.purge()
        if let graphics = controller.host as? any LinuxGraphicsHost {
            linuxDrag = LinuxDragBridge(center: self, host: graphics)
        }
        #if DEBUG || DESKTOP_AUTOMATION
        automation = DebugAutomation.startIfEnabled(controller)
        #endif
    }

    #if DEBUG || DESKTOP_AUTOMATION
    private var automation: DebugAutomation?
    #endif

    /// Re-scans Linux windows for new views to watch; called whenever the window list changes.
    func windowsChanged() {
        linuxDrag?.attachToLinuxViews()
    }

    // MARK: - Native drop targets

    func registerDropHandler(window: UUID, _ handler: @escaping DropHandler) {
        windowHandlers[window] = handler
    }

    func unregisterDropHandler(window: UUID) {
        windowHandlers[window] = nil
    }

    func registerDesktopHandler(_ handler: @escaping DropHandler) {
        desktopHandler = handler
    }

    /// The native handler under a point in UIWindow coordinates: the topmost desktop window
    /// there, or the desktop itself. Nil over a window that takes no drops, or over a Linux
    /// window (those are ishwl's).
    func nativeHandler(atWindowPoint point: CGPoint) -> DropHandler? {
        guard let controller, let desktopPoint = desktopPoint(fromWindowPoint: point) else { return nil }
        let manager = controller.windowManager
        guard let window = manager.visibleStack().first(where: { manager.displayFrame(for: $0).contains(desktopPoint) }) else {
            let size = manager.desktopSize
            return CGRect(origin: .zero, size: size).contains(desktopPoint) ? desktopHandler : nil
        }
        return windowHandlers[window.id]
    }

    func desktopPoint(fromWindowPoint point: CGPoint) -> CGPoint? {
        guard let reference = controller?.input.referenceView, let window = reference.window else { return nil }
        return reference.convert(point, from: window)
    }

    func notify(_ message: String) {
        controller?.notify(message)
    }

    var host: (any LinuxHost)? { controller?.host }
}

/// Registers a window as a drop target for drags that start in Linux apps, for as long as
/// the view is on screen.
struct NativeDropTarget: ViewModifier {
    let window: UUID
    let handler: DragDropCenter.DropHandler

    func body(content: Content) -> some View {
        content
            .onAppear { DragDropCenter.shared.registerDropHandler(window: window, handler) }
            .onDisappear { DragDropCenter.shared.unregisterDropHandler(window: window) }
    }
}

extension View {
    func nativeDropTarget(window: UUID, handler: @escaping DragDropCenter.DropHandler) -> some View {
        modifier(NativeDropTarget(window: window, handler: handler))
    }
}

// MARK: - Presenting UIKit controllers from SwiftUI apps

@MainActor
enum HostPresenter {
    static var topViewController: UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// The share sheet for exported files, anchored at a point (iPad shows it as a popover).
    static func share(_ urls: [URL], at point: CGPoint? = nil) {
        guard let top = topViewController else { return }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            let anchor = point ?? CGPoint(x: top.view.bounds.midX, y: top.view.bounds.midY)
            popover.sourceRect = CGRect(origin: anchor, size: CGSize(width: 1, height: 1))
        }
        top.present(sheet, animated: true)
    }
}
