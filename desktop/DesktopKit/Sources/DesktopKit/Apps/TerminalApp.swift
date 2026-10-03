import GameController
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

enum TerminalApp {
    static func descriptor() -> DesktopAppDescriptor {
        DesktopAppDescriptor(
            id: AppID.terminal, name: "Terminal", symbol: "terminal", category: .system,
            defaultSize: CGSize(width: 760, height: 480), showsOnDesktop: true
        ) { context in
            AnyView(TerminalAppView(context: context))
        }
    }
}

/// Owns the terminal view controller for one window. SwiftUI may rebuild the
/// representable at any time; the session (a live shell) must outlive that.
@MainActor
final class TerminalSession {
    private let host: any LinuxHost
    private let command: String?
    private let cwd: String?
    private var cachedController: UIViewController?

    init(context: AppLaunchContext) {
        host = context.host
        command = context.arguments[AppArgument.command]
        cwd = context.arguments[AppArgument.cwd]
    }

    var controller: UIViewController {
        if let cachedController { return cachedController }
        let controller = host.makeTerminalViewController(command: command, cwd: cwd)
        cachedController = controller
        return controller
    }

    var workingDirectory: String? { cwd }

    /// Types text into the shell as if it were typed.
    func type(_ text: String) {
        guard let view = cachedController?.view, let input = TerminalContainerController.textInputView(in: view) as? UIKeyInput else { return }
        input.insertText(text)
    }

    /// Drops become text, like GNOME Terminal: files as quoted paths separated by spaces
    /// (files from other apps are copied into ~/Downloads first), links and text as is.
    func insert(_ items: [DragItem]) {
        Task {
            var words: [String] = []
            for item in items {
                switch item {
                case .guestFile(let path, _):
                    words.append(ShellQuote.quote(path))
                case .hostFile(let url):
                    let downloads = AppPath.join(host.homeDirectory, "Downloads")
                    _ = await host.run("mkdir -p -- \(ShellQuote.quote(downloads))", cwd: nil, stdin: nil)
                    if let path = try? await GuestTransferService(host: host).importItem(at: url, into: downloads) {
                        words.append(ShellQuote.quote(path))
                    }
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                case .data(let data, let name):
                    let downloads = AppPath.join(host.homeDirectory, "Downloads")
                    _ = await host.run("mkdir -p -- \(ShellQuote.quote(downloads))", cwd: nil, stdin: nil)
                    if let path = try? await GuestTransferService(host: host).importData(data, named: name, into: downloads) {
                        words.append(ShellQuote.quote(path))
                    }
                case .url(let url):
                    words.append(url.absoluteString)
                case .text(let text):
                    words.append(text)
                }
            }
            guard !words.isEmpty else { return }
            type(words.joined(separator: " ") + " ")
        }
    }
}

struct TerminalAppView: View {
    @State private var session: TerminalSession
    @Environment(\.desktopWindowIsFocused) private var isFocused
    private let window: any WindowHandle
    private let desktop: any DesktopActions

    init(context: AppLaunchContext) {
        _session = State(initialValue: TerminalSession(context: context))
        window = context.window
        desktop = context.desktop
    }

    var body: some View {
        TerminalControllerView(session: session, isFocused: isFocused) { [desktop, session] in
            var arguments: [String: String] = [:]
            if let cwd = session.workingDirectory { arguments[AppArgument.cwd] = cwd }
            desktop.open(appID: AppID.terminal, arguments: arguments)
        }
        .background(Color.black)
        .onAppear { window.setTitle("Terminal") }
        .nativeDropTarget(window: window.id) { [session] items, _ in session.insert(items) }
    }
}

private struct TerminalControllerView: UIViewControllerRepresentable {
    let session: TerminalSession
    let isFocused: Bool
    let openNewWindow: @MainActor () -> Void

    func makeUIViewController(context: Context) -> TerminalContainerController {
        let controller = TerminalContainerController(content: session.controller)
        controller.session = session
        controller.openNewWindow = openNewWindow
        return controller
    }

    func updateUIViewController(_ controller: TerminalContainerController, context: Context) {
        controller.setKeyboardFocus(isFocused)
    }
}

/// A fresh container per representable that re-parents the cached session controller.
/// It also owns the terminal's context menu (secondary click or long press) and drops.
private final class TerminalContainerController: UIViewController, UIContextMenuInteractionDelegate, UIDropInteractionDelegate {
    private let content: UIViewController
    weak var session: TerminalSession?
    var openNewWindow: (@MainActor () -> Void)?

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if content.parent != nil {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
        view.addInteraction(UIContextMenuInteraction(delegate: self))
        view.addInteraction(UIDropInteraction(delegate: self))
        // The terminal is drawn by a web view, which would take drops itself and turn text
        // into page content; drops belong to the shell.
        Self.removeWebDropInteractions(in: content.view)
    }

    private static func removeWebDropInteractions(in root: UIView) {
        for subview in root.subviews {
            if subview is WKWebView || subview.superview is WKWebView || String(describing: type(of: subview)).hasPrefix("WK") {
                for interaction in subview.interactions where interaction is UIDropInteraction {
                    subview.removeInteraction(interaction)
                }
            }
            removeWebDropInteractions(in: subview)
        }
    }

    // MARK: Context menu

    private func perform(_ selector: Selector) {
        guard let input = Self.textInputView(in: content.view), input.responds(to: selector) else { return }
        input.perform(selector, with: nil)
    }

    private var webView: WKWebView? {
        func find(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return find(content.view)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let edit = UIMenu(options: .displayInline, children: [
                UIAction(title: "Copy", image: UIImage.themed(systemName: "doc.on.doc")) { _ in
                    self.perform(#selector(UIResponderStandardEditActions.copy(_:)))
                },
                UIAction(title: "Paste", image: UIImage.themed(systemName: "doc.on.clipboard"),
                         attributes: UIPasteboard.general.hasStrings ? [] : .disabled) { _ in
                    self.perform(#selector(UIResponderStandardEditActions.paste(_:)))
                },
                UIAction(title: "Select All", image: UIImage.themed(systemName: "checkmark.circle")) { _ in
                    self.webView?.evaluateJavaScript(
                        "(() => { const d = term.getDocument(); const r = d.createRange(); r.selectNodeContents(d.body); const s = d.getSelection(); s.removeAllRanges(); s.addRange(r); })()")
                },
            ])
            let terminal = UIMenu(options: .displayInline, children: [
                UIAction(title: "Clear Scrollback", image: UIImage.themed(systemName: "eraser")) { _ in
                    self.webView?.evaluateJavaScript("exports.clearScrollback()")
                },
                UIAction(title: "New Terminal Window", image: UIImage.themed(systemName: "plus.rectangle.on.rectangle")) { _ in
                    self.openNewWindow?()
                },
            ])
            return UIMenu(children: [edit, terminal])
        }
    }

    // MARK: Drops

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: DragItemProviders.acceptedTypes.map(\.identifier))
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let providers = session.items.map(\.itemProvider)
        Task { [weak self] in
            let (_, items) = await DragItemProviders.loadItems(from: providers)
            self?.session?.insert(items)
        }
    }

    /// Follows the desktop's window focus. With a hardware keyboard the focused terminal
    /// takes typing at once; on touch alone it waits for a tap, so focusing a window by its
    /// title bar does not throw the on-screen keyboard over the desktop.
    func setKeyboardFocus(_ focused: Bool) {
        guard let input = Self.textInputView(in: content.view) else { return }
        if focused {
            guard GCKeyboard.coalesced != nil, !input.isFirstResponder else { return }
            DispatchQueue.main.async { input.becomeFirstResponder() }
        } else if input.isFirstResponder {
            input.resignFirstResponder()
        }
    }

    static func textInputView(in root: UIView) -> UIView? {
        if root.canBecomeFirstResponder { return root }
        for subview in root.subviews {
            if let found = textInputView(in: subview) { return found }
        }
        return nil
    }
}

#Preview("Terminal") {
    TerminalAppView(context: AppsPreview.context([AppArgument.cwd: "/root/app"]))
        .frame(width: 760, height: 480)
}
