import Foundation

/// `linpad-apps` for MockLinuxHost: an in-memory guest that answers the Store's commands
/// and streams believable install progress, so previews, unit tests and the UX harness can
/// drive the whole Store without the emulator.
@MainActor
final class StoreMockGuest {
    static let shared = StoreMockGuest()

    /// Seconds a mock install takes (UserDefaults "store.mockInstallSeconds" overrides).
    var installSeconds: Double {
        let value = UserDefaults.standard.double(forKey: "store.mockInstallSeconds")
        return value > 0 ? value : 6
    }

    private(set) var installed: Set<String> = ["apk:firefox-esr", "mail-light", "apk:mousepad"]
    private var versions: [String: String] = ["firefox-esr": "128.14.0-r0", "claws-mail": "4.3.0-r0", "mousepad": "0.6.3-r0"]
    private var cancelled = false
    private lazy var index = StoreIndexSource.bundled()

    func handles(_ command: String) -> Bool {
        command.contains("linpad-apps") || command == StoreIndexSource.stampCommand
    }

    func reply(to command: String) async -> CommandResult? {
        guard handles(command) else { return nil }
        if command == StoreIndexSource.stampCommand { return CommandResult(stdout: "") }
        if command.hasSuffix("linpad-apps state") { return CommandResult(stdout: stateJSON() + "\n") }
        if command == "linpad-apps updates" {
            return CommandResult(stdout: #"{"updates":[{"name":"firefox-esr","installed":"128.14.0-r0","available":"128.15.0-r0"},{"name":"openssl","installed":"3.3.4-r0","available":"3.3.5-r0"}]}"# + "\n")
        }
        if command.hasPrefix("linpad-apps plan ") { return CommandResult(stdout: planJSON(ids(in: command, after: "plan")) + "\n") }
        if command == "linpad-apps cancel" {
            cancelled = true
            return CommandResult(stdout: "")
        }
        if command.contains("linpad-apps refresh-icons") { return CommandResult(stdout: "") }
        if command.contains("linpad-apps list --json") { return CommandResult(stdout: "", stderr: "no catalog in the mock", exitCode: 1) }
        return nil
    }

    func stream(_ command: String, onOutput: @escaping @MainActor (String) -> Void) async -> Int32? {
        if command.contains("linpad-apps refresh-index") {
            onOutput("==> Refreshing the package index\n")
            try? await Task.sleep(for: .seconds(1))
            onOutput("==> Store index: \(index?.apps.count ?? 0) apps\n")
            return 0
        }
        for verb in ["install", "remove", "upgrade"] where command.contains("linpad-apps \(verb)") {
            let ids = ids(in: command, after: verb)
            return await run(verb, ids: ids, onOutput: onOutput)
        }
        return nil
    }

    private func run(_ verb: String, ids: [String], onOutput: @escaping @MainActor (String) -> Void) async -> Int32 {
        cancelled = false
        let step = installSeconds / 20
        for id in ids {
            let app = index?.apps.first { $0.id == id }
            let name = app?.name ?? id
            switch verb {
            case "remove":
                onOutput("==> Removing \(name)\n==> @phase \(id) removing\n")
                try? await Task.sleep(for: .seconds(step * 4))
                installed.remove(id)
                onOutput("==> @phase \(id) done\n==> \(name): removed\n")
            case "upgrade":
                onOutput("==> Updating \(name)\n(1/2) Upgrading \(app?.mainPackage ?? id) (1.0-r0 -> 1.1-r0)\n")
                try? await Task.sleep(for: .seconds(step * 4))
                onOutput("(2/2) Upgrading openssl (3.3.4-r0 -> 3.3.5-r0)\n==> Up to date\n")
            default:
                onOutput("==> Installing \(name)\n==> @phase \(id) resolving\n")
                try? await Task.sleep(for: .seconds(step * 2))
                let total = Int64(app?.downloadBytes ?? Int64((app?.sizeMB ?? 40) * 400_000))
                onOutput("==> @phase \(id) downloading\n")
                for i in 1...10 {
                    if cancelled {
                        onOutput("==> @phase \(id) cancelled\n==> \(name): cancelled\n")
                        return 1
                    }
                    onOutput("==> @progress \(id) \(total * Int64(i) / 10) \(total) bytes\n")
                    try? await Task.sleep(for: .seconds(step))
                }
                onOutput("==> @phase \(id) installing\n")
                let count = 6
                for i in 1...count {
                    onOutput("(\(i)/\(count)) Installing \(i == count ? (app?.mainPackage ?? id) : "lib\(i)") (1.0-r0)\n")
                    try? await Task.sleep(for: .seconds(step * 0.6))
                }
                onOutput("==> @phase \(id) configuring\n")
                try? await Task.sleep(for: .seconds(step))
                installed.insert(id)
                if let main = app?.mainPackage { versions[main] = app?.version ?? "1.0-r0" }
                onOutput("==> @phase \(id) done\n==> \(name): installed\n")
            }
        }
        return 0
    }

    private func ids(in command: String, after verb: String) -> [String] {
        guard let range = command.range(of: "linpad-apps \(verb) ") else { return [] }
        return command[range.upperBound...]
            .replacingOccurrences(of: "2>&1", with: "")
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    private func stateJSON() -> String {
        let apps = index?.apps ?? []
        var world: [String] = []
        var packs: [String: Bool] = [:]
        for app in apps where app.isPack { packs[app.id] = installed.contains(app.id) }
        for id in installed {
            guard let app = apps.first(where: { $0.id == id }) else { continue }
            world.append(contentsOf: app.isPack ? (app.packages ?? []) : [app.mainPackage].compactMap { $0 })
        }
        let object: [String: Any] = ["world": world, "installed": versions, "packs": packs]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func planJSON(_ ids: [String]) -> String {
        let plans = ids.map { id -> [String: Any] in
            guard let app = index?.apps.first(where: { $0.id == id }) else { return ["id": id, "error": "unknown app"] }
            let main = Int64(app.downloadBytes ?? Int64((app.sizeMB ?? 30) * 450_000))
            let inst = Int64(app.installedBytes ?? Int64((app.sizeMB ?? 30) * 1_000_000))
            let deps = 7
            let packages = (0..<deps).map { i -> [String: Any] in
                ["name": i == 0 ? (app.mainPackage ?? id) : "lib\(i)", "version": "1.0-r0",
                 "downloadBytes": i == 0 ? main : main / 4, "installedBytes": i == 0 ? inst : inst / 4]
            }
            return ["id": id, "packages": packages,
                    "downloadBytes": main + main / 4 * Int64(deps - 1),
                    "installedBytes": inst + inst / 4 * Int64(deps - 1)]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["plans": plans], options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
