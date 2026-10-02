import Foundation

/// Pre-rendered PNG icons the guest keeps per desktop style (themes/CONTRACT.md):
/// `/usr/share/ish/icon-cache/<style>/<name>.png` and `<name>@2x.png`, with the active
/// style named in `/usr/share/ish/current-style`. freedesktop icon themes are SVG and
/// spread over size directories, so the guest renders them once instead of the host
/// resolving them.
struct LinuxIconCache {
    static let directory = "usr/share/ish/icon-cache"
    static let styleFile = "usr/share/ish/current-style"

    let guestRoot: URL

    var currentStyle: String? {
        guard let data = FileManager.default.contents(atPath: guestRoot.appendingPathComponent(Self.styleFile).path),
              let style = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !style.isEmpty, !style.contains("/") else { return nil }
        return style
    }

    /// The cached icon for a .desktop `Icon=` value, which is either a theme icon name
    /// or a path to an image file.
    func url(forIcon icon: String, style: String? = nil) -> URL? {
        let name = Self.iconName(icon)
        guard !name.isEmpty, let style = style ?? currentStyle else { return nil }
        let folder = guestRoot.appendingPathComponent(Self.directory).appendingPathComponent(style, isDirectory: true)
        return ["\(name)@2x.png", "\(name).png"]
            .map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func iconName(_ icon: String) -> String {
        let file = icon.split(separator: "/").last.map(String.init) ?? ""
        for suffix in [".png", ".svg", ".svgz", ".xpm"] where file.hasSuffix(suffix) {
            return String(file.dropLast(suffix.count))
        }
        return file
    }
}
