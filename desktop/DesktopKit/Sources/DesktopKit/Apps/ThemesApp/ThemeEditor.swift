import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Where user themes live in the guest (CONTRACT-COLORS.md) and how the editor writes them.
@MainActor
enum ThemeFiles {
    static func userDirectory(host: any LinuxHost, id: String) -> String {
        AppPath.join(AppPath.join(AppPath.normalize(host.homeDirectory), ".config/linpad/colors"), id)
    }

    /// colors.toml (Omarchy's schema), theme.conf with the display name, and light.mode for
    /// light themes, as ish-colors expects.
    nonisolated static func files(for theme: ColorTheme) -> [(String, Data)] {
        var files = [("colors.toml", Data(ColorsToml.write(theme).utf8)),
                     ("theme.conf", Data("name=\(theme.name.replacingOccurrences(of: "\n", with: " "))\n".utf8))]
        if !theme.isDark { files.append(("light.mode", Data())) }
        if let icons = theme.iconTheme, !icons.isEmpty { files.append(("icons.theme", Data("\(icons)\n".utf8))) }
        return files
    }

    static func save(_ theme: ColorTheme, host: any LinuxHost) async throws {
        let directory = userDirectory(host: host, id: theme.id)
        let result = await host.run("mkdir -p -- \(directory.shellQuoted) && rm -f -- \(AppPath.join(directory, "light.mode").shellQuoted)",
                                    cwd: nil, stdin: nil)
        guard result.succeeded else { throw LinuxHostError.commandFailed(result) }
        for (name, data) in files(for: theme) {
            try await host.writeFile(AppPath.join(directory, name), data: data)
        }
    }

    /// A folder on the iPad with the theme's files, zipped by the system for sharing.
    nonisolated static func exportZip(_ theme: ColorTheme) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-export-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(theme.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files(for: theme) { try data.write(to: folder.appendingPathComponent(name)) }
        var zipped: URL?
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { url in
            let destination = root.appendingPathComponent("\(theme.id).zip")
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                zipped = destination
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        guard let zipped else { throw CocoaError(.fileWriteUnknown) }
        return zipped
    }

    nonisolated static func exportToml(_ theme: ColorTheme) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(theme.id)-colors.toml")
        try Data(ColorsToml.write(theme).utf8).write(to: url)
        return url
    }

    /// Imports a colors.toml or a theme zip. A zip is unpacked in the guest and only the
    /// files `ThemeImportSanitizer` allows are copied into the user theme folder.
    static func importFile(_ url: URL, host: any LinuxHost) async throws -> ColorTheme {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let baseName = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-colors", with: "")
        if url.pathExtension.lowercased() != "zip" {
            let name = baseName.replacingOccurrences(of: "-", with: " ").capitalized
            guard let theme = ColorsToml.read(String(decoding: data, as: UTF8.self), id: ColorsToml.id(forName: baseName), name: name)
            else { throw ImportError.notATheme }
            try await save(theme, host: host)
            return theme
        }
        let staging = "/tmp/linpad-import-\(UUID().uuidString.prefix(8))"
        defer { Task { _ = await host.run("rm -rf -- \(staging.shellQuoted)", cwd: nil, stdin: nil) } }
        let made = await host.run("mkdir -p -- \(AppPath.join(staging, "x").shellQuoted)", cwd: nil, stdin: nil)
        guard made.succeeded else { throw LinuxHostError.commandFailed(made) }
        try await host.writeFile(AppPath.join(staging, "theme.zip"), data: data)
        let unpacked = await host.run("cd \(AppPath.join(staging, "x").shellQuoted) && unzip -q -o ../theme.zip && "
                                      + "find . -type l -exec echo L {} \\; && find . -type f -perm -u+x -exec echo X {} \\; && find . -type f -exec echo F {} \\;",
                                      cwd: nil, stdin: nil)
        guard unpacked.succeeded else { throw ImportError.unzip(unpacked.failureDescription) }
        var links = Set<String>(), executables = Set<String>(), files: [String] = []
        for line in unpacked.stdout.split(separator: "\n") {
            let path = String(line.dropFirst(2)).replacingOccurrences(of: "./", with: "", options: .anchored)
            switch line.prefix(1) {
            case "L": links.insert(path)
            case "X": executables.insert(path)
            case "F": files.append(path)
            default: break
            }
        }
        let listed = (files + links).map {
            ThemeImportSanitizer.Entry(path: $0, data: Data(), isSymlink: links.contains($0), isExecutable: executables.contains($0))
        }
        let rooted = ThemeImportSanitizer.strippingCommonRoot(listed)
        var entries: [ThemeImportSanitizer.Entry] = []
        for (original, candidate) in zip(listed, rooted) where !ThemeImportSanitizer.sanitize([candidate]).isEmpty {
            let contents = try await host.readFile(AppPath.join(AppPath.join(staging, "x"), original.path))
            entries.append(ThemeImportSanitizer.Entry(path: candidate.path, data: contents))
        }
        let kept = ThemeImportSanitizer.sanitize(entries)
        guard let toml = kept.first(where: { $0.path == "colors.toml" }) else { throw ImportError.notATheme }
        let id = ColorsToml.id(forName: baseName.replacingOccurrences(of: "omarchy-", with: "").replacingOccurrences(of: "-theme", with: ""))
        guard let theme = ColorsToml.read(String(decoding: toml.data, as: UTF8.self), id: id,
                                          name: id.replacingOccurrences(of: "-", with: " ").capitalized)
        else { throw ImportError.notATheme }
        try await save(theme, host: host)
        let directory = userDirectory(host: host, id: id)
        _ = await host.run("mkdir -p -- \(AppPath.join(directory, "backgrounds").shellQuoted)", cwd: nil, stdin: nil)
        for entry in kept where entry.path != "colors.toml" {
            try await host.writeFile(AppPath.join(directory, entry.path), data: entry.data)
        }
        return theme
    }

    enum ImportError: LocalizedError {
        case notATheme
        case unzip(String)

        var errorDescription: String? {
            switch self {
            case .notATheme: "That file has no colors.toml with a background and foreground."
            case .unzip(let reason): "Couldn't unpack the zip: \(reason)"
            }
        }
    }
}

/// The editable copy of a theme: hex strings, so text fields and pickers share one source.
struct ThemeDraft: Equatable {
    var name = "My Theme"
    var isDark = true
    var accent = "#7aa2f7"
    var background = "#1a1b26"
    var foreground = "#a9b1d6"
    var selection = "#292e42"
    var cursor = "#c0caf5"
    var ansi = ["#1a1b26", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#ad8ee6", "#449dab", "#a9b1d6",
                "#414868", "#ff7a93", "#b9f27c", "#ff9e64", "#7da6ff", "#bb9af7", "#0db9d7", "#c0caf5"]

    init() {}

    init(theme: ColorTheme, name: String) {
        self.name = name
        isDark = theme.isDark
        accent = theme.accent
        background = theme.background
        foreground = theme.foreground
        selection = theme.selection ?? selection
        cursor = theme.cursor ?? theme.brightForeground ?? cursor
        if let colors = theme.ansi, colors.count == 16 { ansi = colors }
    }

    var id: String { ColorsToml.id(forName: name) }

    var theme: ColorTheme {
        var colors = ansi
        colors[0] = background
        colors[7] = foreground
        return ColorTheme(id: id, name: name, source: "user", appearance: isDark ? "dark" : "light",
                          accent: accent, background: background, foreground: foreground, selection: selection,
                          selectionForeground: colors[15], cursor: cursor, muted: colors[8], darkBackground: nil,
                          darkerBackground: nil, lighterBackground: nil, brightForeground: colors[15], red: colors[1],
                          ansi: colors, iconTheme: nil, vscode: nil, wallhaven: nil)
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && ([accent, background, foreground, selection, cursor] + ansi).allSatisfy { RGB(hex: $0) != nil }
    }
}

struct ThemeEditorView: View {
    /// Set by the gallery's "Duplicate & Edit" before switching here.
    @MainActor static var pendingDuplicate: ColorTheme?
    /// Set by "Customize" on a wallpaper match: opens that theme as is, under its own name.
    @MainActor static var pendingEdit: ColorTheme?

    let controller: DesktopController
    let host: any LinuxHost
    @Environment(\.desktopTheme) private var theme
    @State private var draft = ThemeDraft()
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isSaving = false
    @State private var isImporting = false

    private static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
                                    "Bright Black", "Bright Red", "Bright Green", "Bright Yellow", "Bright Blue",
                                    "Bright Magenta", "Bright Cyan", "Bright White"]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    SettingsSection(title: "Main colours", symbol: "paintpalette") {
                        colorRow("Accent", $draft.accent, id: "accent")
                        colorRow("Background", $draft.background, id: "background")
                        colorRow("Foreground", $draft.foreground, id: "foreground")
                        colorRow("Selection", $draft.selection, id: "selection")
                        colorRow("Cursor", $draft.cursor, id: "cursor")
                        colorRow("Red (urgent)", $draft.ansi[1], id: "red")
                    }
                    SettingsSection(title: "Terminal colours", symbol: "terminal") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(0..<16, id: \.self) { index in
                                colorRow(Self.ansiNames[index], $draft.ansi[index], id: "ansi\(index)", compact: true)
                                    .disabled(index == 0 || index == 7)
                            }
                        }
                        Text("Black and White are the background and foreground.").font(.caption).foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 420)
            theme.separator.frame(width: 1)
            VStack(alignment: .leading, spacing: 14) {
                Text("Preview").font(.headline)
                ThemePreviewCard(theme: draft.isValid ? draft.theme : nil, fallback: nil, showsNotification: true)
                    .frame(height: 220)
                    .accessibilityIdentifier("themes.editor.preview")
                contrast
                Spacer()
            }
            .padding(20)
            .frame(width: 340)
        }
        .onAppear(perform: takePendingDuplicate)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.zip, UTType(filenameExtension: "toml") ?? .plainText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            importTheme(url)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Theme name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityIdentifier("themes.editor.name")
                Picker("Appearance", selection: $draft.isDark) {
                    Text("Dark").tag(true)
                    Text("Light").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            HStack(spacing: 10) {
                Menu("New") {
                    Button("Blank Dark Theme") { draft = ThemeDraft() }
                    Button("Duplicate Current Theme") {
                        if let current = controller.colorThemes.current { draft = ThemeDraft(theme: current, name: "\(current.name) Copy") }
                    }
                    ForEach(controller.colorThemes.themes) { candidate in
                        Button("From \(candidate.name)") { draft = ThemeDraft(theme: candidate, name: "\(candidate.name) Copy") }
                    }
                }
                .accessibilityIdentifier("themes.editor.new")
                Button("Import…") { isImporting = true }
                Menu("Export") {
                    Button("Theme Folder (.zip)") { share { try ThemeFiles.exportZip(draft.theme) } }
                    Button("colors.toml") { share { try ThemeFiles.exportToml(draft.theme) } }
                }
                .disabled(!draft.isValid)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save & Apply") { save() }
                    .buttonStyle(.primary)
                    .disabled(!draft.isValid || isSaving)
                    .accessibilityIdentifier("themes.editor.save")
            }
            .font(.system(size: 13))
            if let status, statusIsError {
                InlineBanner(kind: .error, message: status, onDismiss: { self.status = nil })
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("themes.editor.status")
            } else if let status {
                Text(status).font(.caption).foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("themes.editor.status")
            }
            Text("Saved to ~/.config/linpad/colors/\(draft.id)/colors.toml.")
                .font(.caption).foregroundStyle(theme.secondaryText)
        }
    }

    private var contrast: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Contrast (WCAG)").font(.headline)
            contrastRow("Text on background", draft.foreground, draft.background, id: "text")
            contrastRow("Accent on background", draft.accent, draft.background, id: "accent")
            contrastRow("Text on selection", draft.foreground, draft.selection, id: "selection")
        }
    }

    private func contrastRow(_ title: String, _ a: String, _ b: String, id: String) -> some View {
        let ratio = RGB(hex: a).flatMap { fg in RGB(hex: b).map { ColorContrast.ratio(fg, $0) } } ?? 1
        let grade = ColorContrast.grade(ratio)
        return HStack {
            Text(title).font(.callout)
            Spacer()
            Text(String(format: "%.1f:1", ratio)).font(.callout.monospacedDigit())
            let fill = grade == .fail ? theme.urgent : (grade == .aaLarge ? Color.orange : Color.green)
            Text(grade.rawValue)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(fill))
                .foregroundStyle(fill.readableLabel)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("themes.editor.contrast.\(id)")
    }

    private func colorRow(_ title: String, _ hex: Binding<String>, id: String, compact: Bool = false) -> some View {
        HStack(spacing: 8) {
            ColorPicker(title, selection: Binding(get: { RGB(hex: hex.wrappedValue)?.color ?? .gray }, set: { color in
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                hex.wrappedValue = RGB(red: Double(r), green: Double(g), blue: Double(b)).hex
            }), supportsOpacity: false)
            .labelsHidden()
            Text(title).font(compact ? .caption : .callout).lineLimit(1)
            Spacer(minLength: 4)
            TextField("#rrggbb", text: hex)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 92)
                .foregroundStyle(RGB(hex: hex.wrappedValue) == nil ? theme.urgent : theme.primaryText)
                .accessibilityIdentifier("themes.editor.hex.\(id)")
        }
    }

    private func takePendingDuplicate() {
        if let edit = Self.pendingEdit {
            Self.pendingEdit = nil
            draft = ThemeDraft(theme: edit, name: edit.name)
            return
        }
        guard let source = Self.pendingDuplicate else { return }
        Self.pendingDuplicate = nil
        draft = ThemeDraft(theme: source, name: "\(source.name) Copy")
    }

    private func save() {
        let candidate = draft.theme
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await ThemeFiles.save(candidate, host: host)
                controller.colorThemes.upsertLocal(candidate)
                await controller.colorThemes.load(host: host)
                controller.applyColorTheme(candidate.id)
                statusIsError = false
                status = "Saved \(candidate.name) and applied it."
            } catch {
                statusIsError = true
                status = "Couldn't save: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    private func importTheme(_ url: URL) {
        Task {
            do {
                let imported = try await ThemeFiles.importFile(url, host: host)
                controller.colorThemes.upsertLocal(imported)
                await controller.colorThemes.load(host: host)
                draft = ThemeDraft(theme: imported, name: imported.name)
                statusIsError = false
                status = "Imported \(imported.name)."
            } catch {
                statusIsError = true
                status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func share(_ make: () throws -> URL) {
        do {
            HostPresenter.share([try make()])
        } catch {
            statusIsError = true
            status = "Couldn't export: \(error.localizedDescription)"
        }
    }
}
