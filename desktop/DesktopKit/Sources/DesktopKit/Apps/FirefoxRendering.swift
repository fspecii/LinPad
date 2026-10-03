import SwiftUI

/// How Firefox renders while windowed, as the normal-scale column of ishwl's
/// /etc/ishwl/app-scale ("firefox-esr 2 1"). Scale 1 draws a quarter of the pixels:
/// embedded video drops far fewer frames and uses less CPU, but text is upscaled and soft.
/// Fullscreen always renders at scale 1. ishwl reads the file when an app connects
/// (wl-bridge/src/misc.c), so a running Firefox keeps its scale until it is reopened.
enum FirefoxRendering: String, CaseIterable, Identifiable {
    case sharpText
    case smoothVideo

    static let path = "/etc/ishwl/app-scale"
    static let program = "firefox-esr"
    static let fullscreenScale = 1

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sharpText: "Sharp Text"
        case .smoothVideo: "Smooth Video"
        }
    }

    var scale: Int { self == .sharpText ? 2 : 1 }

    /// The mode the file sets; a missing line means ishwl's default (scale 2).
    static func current(in contents: String) -> FirefoxRendering {
        // ishwl applies the last matching line.
        guard let line = contents.split(separator: "\n").last(where: { isFirefoxLine($0) }) else { return .sharpText }
        let fields = line.split(whereSeparator: \.isWhitespace)
        return fields.count >= 2 && fields[1] == "1" ? .smoothVideo : .sharpText
    }

    /// `contents` with Firefox's line set to this mode, in place of the first one there was
    /// (later duplicates dropped); every other line is kept as it was.
    func rewrite(_ contents: String) -> String {
        let entry = "\(Self.program) \(scale) \(Self.fullscreenScale)"
        var lines = contents.isEmpty ? [] : contents.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var replaced = false
        lines = lines.compactMap { line in
            guard Self.isFirefoxLine(Substring(line)) else { return line }
            defer { replaced = true }
            return replaced ? nil : entry
        }
        if !replaced { lines.append(entry) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isFirefoxLine(_ line: Substring) -> Bool {
        line.split(whereSeparator: \.isWhitespace).first == Substring(program)
    }

    static func load(from host: any LinuxHost) async -> FirefoxRendering {
        guard let data = try? await host.readFile(path) else { return .sharpText }
        return current(in: String(decoding: data, as: UTF8.self))
    }

    func apply(to host: any LinuxHost) async throws {
        let existing = (try? await host.readFile(Self.path)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        _ = await host.run("mkdir -p -- \(ShellQuote.quote("/etc/ishwl"))")
        try await host.writeFile(Self.path, data: Data(rewrite(existing).utf8))
    }
}

/// Settings › Performance.
struct PerformanceSettingsSection: View {
    let host: any LinuxHost
    @Environment(\.desktopTheme) private var theme
    @State private var mode = FirefoxRendering.sharpText
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        SettingsSection(title: "Performance", symbol: "speedometer") {
            SettingsRow(title: "Firefox rendering") {
                Picker("Firefox rendering", selection: $mode) {
                    ForEach(FirefoxRendering.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .disabled(!loaded)
                .accessibilityIdentifier("settings.firefoxRendering")
            }
            Text(message ?? "Sharp Text renders Firefox at full resolution. Smooth Video renders it at half, so videos in a page drop far fewer frames and use less CPU, but text looks softer. Fullscreen video always uses the faster setting.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.firefoxRendering.note")
        }
        .task {
            mode = await FirefoxRendering.load(from: host)
            loaded = true
        }
        .onChange(of: mode) { _, newMode in
            guard loaded else { return }
            Task {
                do {
                    try await newMode.apply(to: host)
                    message = "Saved. Close and reopen Firefox to switch to \(newMode.title)."
                } catch {
                    message = "Could not save the setting: \(error.localizedDescription)"
                }
            }
        }
    }
}
