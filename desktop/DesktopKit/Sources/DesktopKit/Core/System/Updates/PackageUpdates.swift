import Foundation

/// An Alpine package with a newer version in the configured repositories.
public struct PackageUpdate: Equatable, Hashable, Sendable {
    public let name: String
    public let installed: String
    public let available: String
}

public enum ApkCommands {
    /// Refreshes the indexes, then lists upgradable packages ("name-1.0-r0   < 1.1-r0").
    public static let listUpgrades = "apk update -q >/dev/null 2>&1; apk version -l '<' 2>&1"

    /// `apk upgrade`, then the same Mesa re-pin linpad-apps runs after every package change:
    /// Mesa comes from Alpine edge and needs edge's libdrm, libxcb and wayland-libs-client.
    public static let upgrade = """
        apk upgrade --no-progress 2>&1
        status=$?
        if [ -f /usr/lib/libgallium-26.2.3.so ]; then
            apk add -q --no-progress --upgrade --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
                libdrm libxcb wayland-libs-client 2>&1
        fi
        exit $status
        """

    public static func parseUpgradable(_ output: String) -> [PackageUpdate] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, parts[1] == "<" else { return nil }
            guard let (name, installed) = splitNameVersion(String(parts[0])) else { return nil }
            return PackageUpdate(name: name, installed: installed, available: String(parts[2]))
        }
    }

    /// "py3-pip-24.3.1-r0" -> ("py3-pip", "24.3.1-r0"): the version is the last
    /// dash-separated field that starts with a digit, and what follows it.
    static func splitNameVersion(_ text: String) -> (String, String)? {
        let fields = text.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count >= 2,
              let index = fields.indices.dropFirst().last(where: { fields[$0].first?.isNumber == true }) else { return nil }
        return (fields[..<index].joined(separator: "-"), fields[index...].joined(separator: "-"))
    }
}
