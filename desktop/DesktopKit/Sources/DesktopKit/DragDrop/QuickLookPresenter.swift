import QuickLook
import SwiftUI
import UIKit

/// macOS-style Quick Look: Space toggles a preview of the selection, the arrow keys move
/// through it while it is open (through the selection's files, or through the folder via
/// `onStep` when one file is selected), and Space or Esc closes it. Guest files are exported
/// through the guest first (GuestTransferService), and cached while unchanged.
@MainActor
final class QuickLookPresenter: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    static let shared = QuickLookPresenter()

    enum Step {
        case previous, next, up, down
    }

    private var urls: [URL] = []
    private weak var presented: KeyedPreviewController?
    private var onStep: ((Step) -> Void)?
    /// Guest path → (size, modification date, exported copy).
    private var cache: [String: (Int64, Date?, URL)] = [:]

    var isPresenting: Bool { presented != nil }

    func preview(_ urls: [URL], startingAt index: Int = 0, onStep: ((Step) -> Void)? = nil) {
        guard !urls.isEmpty, let top = HostPresenter.topViewController else { return }
        if let presented {
            replace(urls, index: index)
            self.onStep = onStep
            presented.becomeFirstResponder()
            return
        }
        self.urls = urls
        self.onStep = onStep
        let controller = KeyedPreviewController()
        controller.dataSource = self
        controller.delegate = self
        controller.currentPreviewItemIndex = min(index, urls.count - 1)
        controller.onKey = { [weak self] key in self?.handle(key) }
        presented = controller
        top.present(controller, animated: true)
    }

    /// Shows other files in the open preview (the selection moved).
    func replace(_ urls: [URL], index: Int = 0) {
        guard let presented, !urls.isEmpty else { return }
        self.urls = urls
        presented.reloadData()
        presented.currentPreviewItemIndex = min(index, urls.count - 1)
        // Reloading moves the first responder into the new preview's views, which would
        // take Space and Esc away from the panel's key commands.
        DispatchQueue.main.async { [weak presented] in presented?.becomeFirstResponder() }
    }

    func dismiss() {
        presented?.dismiss(animated: true)
        presented = nil
        onStep = nil
    }

    private func handle(_ key: KeyedPreviewController.Key) {
        guard let presented else { return }
        switch key {
        case .close:
            dismiss()
        case .previous, .next, .up, .down:
            let forward = key == .next || key == .down
            if urls.count > 1 {
                let index = presented.currentPreviewItemIndex + (forward ? 1 : -1)
                if urls.indices.contains(index) { presented.currentPreviewItemIndex = index }
            } else {
                let step: Step = key == .previous ? .previous : key == .next ? .next : key == .up ? .up : .down
                onStep?(step)
            }
        }
    }

    // MARK: Exporting guest files

    /// The host copy of a guest file for previewing, exported again only when it changed.
    func exportedURL(for entry: FileEntry, transfer: GuestTransferService,
                     progress: GuestTransferService.ProgressHandler? = nil) async throws -> URL {
        if let (size, modified, url) = cache[entry.path], size == entry.size, modified == entry.modified,
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let url = try await transfer.exportItem(entry.path, isDirectory: false, progress: progress)
        cache[entry.path] = (entry.size, entry.modified, url)
        return url
    }

    // MARK: QLPreviewController

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        MainActor.assumeIsolated { urls[min(index, urls.count - 1)] as NSURL }
    }

    nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
        MainActor.assumeIsolated {
            presented = nil
            onStep = nil
        }
    }
}

/// QLPreviewController that answers the keyboard like the macOS Quick Look panel.
final class KeyedPreviewController: QLPreviewController {
    enum Key {
        case close, previous, next, up, down
    }

    var onKey: ((Key) -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        let inputs: [(String, Key)] = [
            (" ", .close), (UIKeyCommand.inputEscape, .close),
            (UIKeyCommand.inputLeftArrow, .previous), (UIKeyCommand.inputRightArrow, .next),
            (UIKeyCommand.inputUpArrow, .up), (UIKeyCommand.inputDownArrow, .down),
        ]
        return inputs.map { input, key in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(performKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            command.title = "\(key)"
            return command
        }
    }

    @objc private func performKey(_ command: UIKeyCommand) {
        let key: Key
        switch command.input {
        case UIKeyCommand.inputLeftArrow: key = .previous
        case UIKeyCommand.inputRightArrow: key = .next
        case UIKeyCommand.inputUpArrow: key = .up
        case UIKeyCommand.inputDownArrow: key = .down
        default: key = .close
        }
        onKey?(key)
    }
}
