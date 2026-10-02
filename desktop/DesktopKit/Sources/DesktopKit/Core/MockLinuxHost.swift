import UIKit

/// An in-memory stand-in for the emulator, for previews, tests and app development
/// before the real host exists. Commands it does not recognise fail like a missing binary.
@MainActor
public final class MockLinuxHost: LinuxHost {
    public let hostName: String
    public let homeDirectory = "/root"

    /// Simulated per-command latency; the real emulator takes tens to hundreds of milliseconds.
    public var latency: Duration

    private enum Node {
        case directory
        case file(Data)
    }

    private var nodes: [String: Node]
    private let bootDate = Date()

    public init(hostName: String = "ish", latency: Duration = .milliseconds(60)) {
        self.hostName = hostName
        self.latency = latency
        self.nodes = Self.seedFileSystem(hostName: hostName)
    }

    public func run(_ command: String, cwd: String?, stdin: Data?) async -> CommandResult {
        try? await Task.sleep(for: latency)
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmed {
        case "uname -a":
            return CommandResult(stdout: "Linux \(hostName) 4.20.69-ish #1 SMP PREEMPT aarch64 Linux\n")
        case "whoami":
            return CommandResult(stdout: "root\n")
        case "hostname":
            return CommandResult(stdout: "\(hostName)\n")
        case "ps", "ps aux", "ps -ef":
            return CommandResult(stdout: Self.processTable)
        case "cat /proc/loadavg":
            return CommandResult(stdout: loadAverage())
        case "head -1 /proc/stat":
            return CommandResult(stdout: cpuStat())
        case "cat /proc/meminfo":
            return CommandResult(stdout: memoryInfo())
        default:
            break
        }

        if let reply = MockMediaPlayer.shared.reply(to: trimmed) {
            return reply
        }
        if trimmed.hasPrefix("mkdir -p -- ") {
            let quoted = trimmed.dropFirst("mkdir -p -- ".count)
            guard quoted.hasPrefix("'"), let end = quoted.dropFirst().firstIndex(of: "'") else {
                return CommandResult(stdout: "", stderr: "mkdir: bad path\n", exitCode: 1)
            }
            makeDirectories(String(quoted[quoted.index(after: quoted.startIndex)..<end]))
            return CommandResult(stdout: "")
        }
        if trimmed.hasPrefix("ish-apply-colors --fonts") {
            return CommandResult(stdout: "fonts: set\n")
        }
        if trimmed.hasPrefix("ish-apply-style ") {
            return applyStyle(String(trimmed.dropFirst("ish-apply-style ".count)))
        }
        if trimmed.hasPrefix("cat "), let path = Self.singlePathArgument(of: trimmed, after: "cat ") {
            return contentsResult(at: path)
        }
        let name = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        return CommandResult(stdout: "", stderr: "sh: \(name): not found\n", exitCode: 127)
    }

    public func listDirectory(_ path: String) async throws -> [FileEntry] {
        try? await Task.sleep(for: latency)
        let directory = Self.normalize(path)
        guard case .directory = nodes[directory] else { throw LinuxHostError.invalidPath(path) }
        let prefix = directory == "/" ? "/" : directory + "/"

        return nodes.compactMap { entryPath, node -> FileEntry? in
            guard entryPath != directory, entryPath.hasPrefix(prefix) else { return nil }
            let name = String(entryPath.dropFirst(prefix.count))
            guard !name.isEmpty, !name.contains("/") else { return nil }
            switch node {
            case .directory:
                return FileEntry(path: entryPath, name: name, isDirectory: true,
                                 size: 4096, modified: bootDate, permissions: "drwxr-xr-x")
            case .file(let data):
                let executable = entryPath.hasPrefix("/usr/bin/")
                return FileEntry(path: entryPath, name: name, isDirectory: false,
                                 size: Int64(data.count), modified: bootDate,
                                 permissions: executable ? "-rwxr-xr-x" : "-rw-r--r--")
            }
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public func readFile(_ path: String) async throws -> Data {
        try? await Task.sleep(for: latency)
        guard case .file(let data) = nodes[Self.normalize(path)] else {
            throw LinuxHostError.invalidPath(path)
        }
        return data
    }

    public func writeFile(_ path: String, data: Data) async throws {
        try? await Task.sleep(for: latency)
        let filePath = Self.normalize(path)
        guard case .directory = nodes[Self.parent(of: filePath)] else {
            throw LinuxHostError.invalidPath(path)
        }
        if case .directory = nodes[filePath] { throw LinuxHostError.invalidPath(path) }
        nodes[filePath] = .file(data)
    }

    public func makeTerminalViewController(command: String?, cwd: String?) -> UIViewController {
        MockTerminalViewController(
            prompt: "root@\(hostName):\(cwd ?? "~")# \(command ?? "")")
    }

    // MARK: - Icon packs (themes/CONTRACT.md)

    private static let iconPacks = [("Adwaita", "Adwaita", UIColor.systemGray), ("Papirus", "Papirus", UIColor.systemTeal),
                                    ("Papirus-Dark", "Papirus Dark", UIColor.systemIndigo)]

    private func applyStyle(_ arguments: String) -> CommandResult {
        let words = arguments.split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
        switch words.first {
        case "--icon-themes":
            return CommandResult(stdout: Self.iconPacks.map { "\($0.0)\t\($0.1)\n" }.joined())
        case "--icon-previews":
            for (id, _, color) in Self.iconPacks {
                let directory = "/usr/share/ish/icon-previews/\(id)"
                makeDirectories(directory)
                for (index, name) in ["folder", "utilities-terminal", "system-file-manager", "web-browser"].enumerated() {
                    nodes["\(directory)/\(name).png"] = .file(Self.previewPNG(color, shape: index))
                }
            }
            return CommandResult(stdout: "icon previews: /usr/share/ish/icon-previews\n")
        case "--icons" where words.count == 2:
            let pick = words[1]
            if pick == "match" {
                nodes["/usr/share/ish/icon-theme"] = nil
            } else {
                guard Self.iconPacks.contains(where: { $0.0 == pick }) else {
                    return CommandResult(stdout: "", stderr: "ish-apply-style: icon theme '\(pick)' is not installed\n", exitCode: 1)
                }
                makeDirectories("/usr/share/ish")
                nodes["/usr/share/ish/icon-theme"] = .file(Data("\(pick)\n".utf8))
            }
            return CommandResult(stdout: "icons: \(pick)\n")
        default:
            return CommandResult(stdout: "", stderr: "sh: ish-apply-style: not found\n", exitCode: 127)
        }
    }

    private func makeDirectories(_ path: String) {
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if nodes[current] == nil { nodes[current] = .directory }
        }
    }

    private static func previewPNG(_ color: UIColor, shape: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).pngData { context in
            color.setFill()
            let rect = CGRect(x: 6, y: 6, width: 52, height: 52)
            (shape % 2 == 0 ? UIBezierPath(roundedRect: rect, cornerRadius: 12) : UIBezierPath(ovalIn: rect)).fill()
        }
    }

    // MARK: - Canned data

    private func contentsResult(at path: String) -> CommandResult {
        switch nodes[Self.normalize(path)] {
        case .file(let data):
            return CommandResult(stdout: String(decoding: data, as: UTF8.self))
        case .directory:
            return CommandResult(stdout: "", stderr: "cat: read error: Is a directory\n", exitCode: 1)
        case nil:
            return CommandResult(stdout: "", stderr: "cat: can't open '\(path)': No such file or directory\n",
                                 exitCode: 1)
        }
    }

    /// Wanders a little each call so the panel meters visibly respond in previews.
    private func loadAverage() -> String {
        let one = Double.random(in: 0.15...1.6)
        return String(format: "%.2f %.2f %.2f 1/42 1337\n", one, one * 0.8, one * 0.6)
    }

    private var cpuJiffies: (busy: Int, idle: Int) = (0, 0)

    private func cpuStat() -> String {
        cpuJiffies.busy += Int.random(in: 10...160)
        cpuJiffies.idle += Int.random(in: 100...300)
        return "cpu  \(cpuJiffies.busy) 0 0 \(cpuJiffies.idle)\n"
    }

    private func memoryInfo() -> String {
        let totalKiB = 4_045_312
        let availableKiB = Int.random(in: 1_900_000...2_700_000)
        return """
        MemTotal:        \(totalKiB) kB
        MemFree:         \(availableKiB - 400_000) kB
        MemAvailable:    \(availableKiB) kB
        Buffers:           81920 kB
        Cached:           318464 kB
        SwapTotal:             0 kB
        SwapFree:              0 kB

        """
    }

    private static let processTable = """
    PID   USER     TIME  COMMAND
        1 root      0:00 /sbin/init
       42 root      0:00 /bin/login -f root
       57 root      0:00 -ash
      118 root      0:01 /usr/sbin/sshd
      131 root      0:00 ps

    """

    private static func seedFileSystem(hostName: String) -> [String: Node] {
        func file(_ text: String) -> Node { .file(Data(text.utf8)) }
        return [
            "/": .directory,
            "/root": .directory,
            "/root/Documents": .directory,
            "/root/projects": .directory,
            "/root/.profile": file("export PS1='\\u@\\h:\\w\\$ '\n"),
            "/root/notes.txt": file("Welcome to the iSH desktop.\nThis file lives in the mock host.\n"),
            "/root/hello.py": file("print(\"hello from alpine\")\n"),
            "/root/Documents/todo.md": file("- [ ] try the terminal\n- [ ] install packages with apk\n"),
            "/root/projects/README": file("Put your code here.\n"),
            "/etc": .directory,
            "/etc/hostname": file("\(hostName)\n"),
            "/etc/os-release": file("""
                NAME="Alpine Linux"
                ID=alpine
                VERSION_ID=3.21.0
                PRETTY_NAME="Alpine Linux v3.21"

                """),
            "/etc/motd": file("Welcome to Alpine!\n"),
            "/usr": .directory,
            "/usr/bin": .directory,
            "/usr/bin/env": file("\u{7F}ELF"),
            "/usr/bin/python3": file("\u{7F}ELF"),
            "/usr/bin/vi": file("\u{7F}ELF"),
            "/tmp": .directory,
        ]
    }

    // MARK: - Paths

    private static func normalize(_ path: String) -> String {
        let components = path.split(separator: "/").filter { $0 != "." }
        return "/" + components.joined(separator: "/")
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    private static func singlePathArgument(of command: String, after prefix: String) -> String? {
        var argument = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if argument.count >= 2, argument.hasPrefix("'"), argument.hasSuffix("'") {
            argument = String(argument.dropFirst().dropLast())
        }
        guard argument.hasPrefix("/"), !argument.contains(" ") else { return nil }
        return argument
    }
}

private final class MockTerminalViewController: UIViewController {
    private let prompt: String

    init(prompt: String) {
        self.prompt = prompt
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let label = UILabel()
        label.text = prompt + "\u{2588}"
        label.textColor = UIColor(red: 0.75, green: 0.95, blue: 0.75, alpha: 1)
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
        ])
    }
}
