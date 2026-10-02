import Foundation

/// An application from the guest's /usr/share/applications (freedesktop .desktop files).
struct LinuxDesktopEntry: Equatable, Sendable {
    /// The file name without ".desktop", which is also what apps use as their Wayland app_id.
    let id: String
    let name: String
    /// `Exec` with the field codes (%f, %U, ...) removed.
    let command: String
    let icon: String
    let categories: [String]
    let startupWMClass: String?

    static let directory = "/usr/share/applications"

    /// A single shell command that prints every entry, each preceded by a `[[file NAME]]` marker.
    static let listingCommand = """
        for f in \(directory)/*.desktop; do [ -f "$f" ] || continue; printf '\\n[[file %s]]\\n' "${f##*/}"; cat "$f"; done
        """

    static func parseListing(_ output: String) -> [LinuxDesktopEntry] {
        var entries: [LinuxDesktopEntry] = []
        var fileName: String?
        var body: [Substring] = []

        func flush() {
            if let fileName, let entry = parse(fileName: fileName, lines: body) {
                entries.append(entry)
            }
            body.removeAll()
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[[file "), line.hasSuffix("]]") {
                flush()
                fileName = String(line.dropFirst(7).dropLast(2))
            } else {
                body.append(line)
            }
        }
        flush()
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parse(fileName: String, lines: [Substring]) -> LinuxDesktopEntry? {
        var inMainGroup = false
        var fields: [String: String] = [:]
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inMainGroup = line == "[Desktop Entry]"
                continue
            }
            guard inMainGroup, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            // Localized keys ("Name[de]") are skipped; the desktop is English-only.
            guard !key.contains("[") else { continue }
            fields[key] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["Type"] == "Application",
              fields["NoDisplay"] != "true", fields["Hidden"] != "true",
              fields["Terminal"] != "true",
              let name = fields["Name"], let exec = fields["Exec"] else { return nil }
        let command = stripFieldCodes(exec)
        guard !command.isEmpty else { return nil }
        let id = fileName.hasSuffix(".desktop") ? String(fileName.dropLast(8)) : fileName
        return LinuxDesktopEntry(
            id: id, name: name, command: command, icon: fields["Icon"] ?? "",
            categories: (fields["Categories"] ?? "").split(separator: ";").map(String.init),
            startupWMClass: fields["StartupWMClass"])
    }

    static func stripFieldCodes(_ exec: String) -> String {
        exec.split(separator: " ")
            .filter { !($0.count == 2 && $0.hasPrefix("%")) }
            .joined(separator: " ")
            .replacingOccurrences(of: "%%", with: "%")
    }

    /// Whether a Wayland app_id belongs to this entry (GTK uses the desktop id, or
    /// the reverse-DNS application id whose last component is the binary name).
    func matches(appID: String) -> Bool {
        let lowered = appID.lowercased()
        if lowered == id.lowercased() || lowered == startupWMClass?.lowercased() { return true }
        let binary = (command.split(separator: " ").first.map(String.init) ?? "")
            .split(separator: "/").last.map { $0.lowercased() } ?? ""
        return lowered == binary || lowered.hasSuffix("." + binary)
    }

    /// An SF Symbol standing in for the freedesktop icon.
    var symbol: String {
        let all = Set(categories)
        let lookup: [(String, String)] = [
            ("WebBrowser", "globe"), ("FileManager", "folder"), ("TextEditor", "doc.text"),
            ("TerminalEmulator", "terminal"), ("Calculator", "plusminus"), ("Graphics", "photo"),
            ("AudioVideo", "play.rectangle"), ("Office", "doc.richtext"), ("Development", "hammer"),
            ("Game", "gamecontroller"), ("Settings", "gearshape"), ("System", "cpu"),
            ("Network", "network"), ("Utility", "wrench.and.screwdriver"),
        ]
        return lookup.first { all.contains($0.0) }?.1 ?? "macwindow"
    }
}
