import DesktopKit
import UIKit

/// The mock host as a graphics host, so `-desktop.fakeLinuxWindow` can map a Linux
/// window without a guest (LinuxGUIBridge.showFakeToplevelIfRequested).
@MainActor
final class HarnessGraphicsHost: LinuxGraphicsHost {
    private let base = MockLinuxHost()

    var guestRootURL: URL? { nil }
    var hostName: String { base.hostName }
    var homeDirectory: String { base.homeDirectory }

    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult {
        await base.run(command, cwd: cwd, stdin: stdin)
    }

    func stream(_ command: String, cwd: String?, onOutput: @escaping @MainActor (String) -> Void) async -> Int32 {
        await base.stream(command, cwd: cwd, onOutput: onOutput)
    }

    func listDirectory(_ path: String) async throws -> [FileEntry] { try await base.listDirectory(path) }
    func readFile(_ path: String) async throws -> Data { try await base.readFile(path) }
    func writeFile(_ path: String, data: Data) async throws { try await base.writeFile(path, data: data) }

    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController {
        base.makeTerminalViewController(command: command, cwd: cwd)
    }
}
