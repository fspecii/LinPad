import SwiftUI
import UIKit

/// Canned Linux host for the apps' `#Preview`s. Deliberately independent of Core's mock.
@MainActor
final class AppsPreviewHost: LinuxHost {
    let hostName = "ipad"
    let homeDirectory = "/root"

    func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult {
        if command.hasPrefix("ps ") {
            return CommandResult(stdout: Self.processSnapshot)
        }
        if command.hasPrefix("apk search") {
            return CommandResult(stdout: """
                nodejs-22.11.0-r0 - JavaScript runtime built on V8 engine - LTS version
                nodejs-dev-22.11.0-r0 - JavaScript runtime built on V8 engine - LTS version (development files)
                py3-pip-24.3.1-r0 - Tool for installing and managing Python packages
                """)
        }
        if command.hasPrefix("apk info") {
            return CommandResult(stdout: """
                busybox-1.37.0-r8 - Size optimized toolbox of many common UNIX utilities
                git-2.47.1-r0 - Distributed version control system
                nodejs-22.11.0-r0 - JavaScript runtime built on V8 engine - LTS version
                npm-10.9.1-r0 - The package manager for JavaScript
                """)
        }
        if command.hasPrefix("uname") {
            return CommandResult(stdout: """
                Linux ipad 4.20.69-ish SUPER AWESOME aarch64 Linux
                __DK_SECTION__
                3.21.0
                __DK_SECTION__
                v22.11.0
                __DK_SECTION__
                10.9.1
                """)
        }
        return CommandResult(stdout: "")
    }

    func stream(_ command: String, cwd: String?,
                onOutput: @escaping @MainActor (String) -> Void) async -> Int32 {
        onOutput("(1/1) Installing \(command)\nOK: 120 MiB in 42 packages\n")
        return 0
    }

    func listDirectory(_ path: String) async throws -> [FileEntry] {
        let names: [(String, Bool, Int64)] = [
            ("src", true, 0), ("node_modules", true, 0), ("public", true, 0), (".git", true, 0),
            ("package.json", false, 812), ("vite.config.ts", false, 214), ("README.md", false, 2_048),
            ("index.html", false, 361), (".gitignore", false, 48),
        ]
        return names.map { name, isDirectory, size in
            FileEntry(path: AppPath.join(path, name), name: name, isDirectory: isDirectory,
                      size: size, modified: Date(timeIntervalSince1970: 1_790_000_000))
        }
    }

    func readFile(_ path: String) async throws -> Data {
        Data("""
            import { defineConfig } from 'vite'
            import react from '@vitejs/plugin-react'

            // https://vitejs.dev/config/
            export default defineConfig({
              plugins: [react()],
              server: { host: true, port: 5173 },
            })

            """.utf8)
    }

    func writeFile(_ path: String, data: Data) async throws {}

    func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController {
        let controller = UIViewController()
        let label = UILabel()
        label.text = "root@ipad:\(cwd ?? "~")# \(command ?? "")"
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        label.textColor = .green
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .black
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 8),
        ])
        return controller
    }

    private static let processSnapshot = """
          PID  PPID USER       VSZ STAT COMMAND          COMMAND
            1     0 root      1.6m S    init             /sbin/init
           42     1 root      2.1m S    sh               -sh
          108    42 root      712m S    node             node /usr/bin/npx vite
          131    42 root      1.1g S    claude           claude
          200   131 root      3.2m R    ps               ps -o pid,ppid,user,vsz,stat,comm,args
        __DK_LOADAVG__
        0.42 0.36 0.30 2/97 200
        __DK_MEMINFO__
        MemTotal:        8000000 kB
        MemFree:         2100000 kB
        MemAvailable:    5200000 kB
        """
}

@MainActor
final class AppsPreviewWindow: WindowHandle {
    let id = UUID()
    func setTitle(_ title: String) {}
    func close() {}
}

@MainActor
final class AppsPreviewDesktop: DesktopActions {
    func open(appID: String, arguments: [String: String]) {}
    func notify(_ message: String) {}
}

enum AppsPreview {
    @MainActor
    static func context(_ arguments: [String: String] = [:]) -> AppLaunchContext {
        AppLaunchContext(host: AppsPreviewHost(), arguments: arguments,
                         window: AppsPreviewWindow(), desktop: AppsPreviewDesktop())
    }
}
