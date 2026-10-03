import SwiftUI

/// The full-screen screensaver: any tap, pointer movement or key press ends it.
struct ScreensaverOverlay: View {
    let controller: DesktopController
    @AppStorage(IdleSettings.styleKey) private var styleID = ScreensaverStyle.logo.rawValue
    @FocusState private var isFocused: Bool

    var body: some View {
        ScreensaverCanvas(style: ScreensaverStyle(rawValue: styleID) ?? .logo)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { controller.idle.dismissScreensaver() }
            .onContinuousHover { _ in controller.idle.noteActivity() }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress { _ in
                controller.idle.dismissScreensaver()
                return .handled
            }
            .onAppear { isFocused = true }
            .accessibilityElement()
            .accessibilityLabel("Screensaver")
            .accessibilityHint("Tap or press any key to return")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("desktop.screensaver")
    }
}

/// One screensaver look, at any size (Settings shows it small as a preview).
struct ScreensaverCanvas: View {
    let style: ScreensaverStyle
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        TimelineView(.animation(minimumInterval: style == .clock ? 1 : 1.0 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    switch style {
                    case .logo: LogoScreensaver(time: time, size: proxy.size, accent: theme.accent)
                    case .matrix: MatrixScreensaver(time: time, accent: theme.accent)
                    case .clock: ClockScreensaver(date: context.date, time: time, size: proxy.size, accent: theme.accent)
                    }
                }
            }
        }
    }

    /// A slow drift around the centre so nothing stays in one place on the panel.
    static func drift(_ time: TimeInterval, in size: CGSize, content: CGSize) -> CGPoint {
        let rangeX = max(0, (size.width - content.width) / 2 - 8)
        let rangeY = max(0, (size.height - content.height) / 2 - 8)
        return CGPoint(x: size.width / 2 + rangeX * sin(time / 23), y: size.height / 2 + rangeY * sin(time / 17 + 1))
    }
}

/// The LinPad wordmark in block letters, decoding from random glyphs like a terminal
/// text effect, holding, then scrambling away again.
private struct LogoScreensaver: View {
    let time: TimeInterval
    let size: CGSize
    let accent: Color

    static let art = [
        "█             ████              █",
        "█    █        █   █             █",
        "█       ████  ████   ███    ████",
        "█    █  █   █ █     █  ██  █   █",
        "█    █  █   █ █     █  ██  █   █",
        "█████ █ █   █ █      ██ █   ████",
    ]
    private static let glyphs = Array("!#$%&*+-/0123456789<=>?@ABCDEFGHJKLMNPQRSTUVWXYZ[]^_{|}~")
    private static let cycle: TimeInterval = 9

    var body: some View {
        let columns = Self.art.map(\.count).max() ?? 1
        let fontSize = max(6, min(size.width * 0.62 / CGFloat(columns) / 0.6, 30))
        let phase = time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
        let lines = Self.art.enumerated().map { row, line in
            String(line.enumerated().map { column, character in
                Self.render(character, row: row, column: column, columns: columns, phase: phase, time: time)
            })
        }
        let block = Text(lines.joined(separator: "\n"))
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundStyle(LinearGradient(colors: [accent, accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            .shadow(color: accent.opacity(0.6), radius: fontSize * 0.4)
            .fixedSize()
        let content = CGSize(width: CGFloat(columns) * fontSize * 0.6, height: CGFloat(Self.art.count) * fontSize * 1.2)
        block.position(ScreensaverCanvas.drift(time, in: size, content: content))
    }

    /// Decodes left to right over the first 35% of the cycle, holds, and scrambles away
    /// over the last 20%.
    private static func render(_ character: Character, row: Int, column: Int, columns: Int,
                               phase: Double, time: TimeInterval) -> Character {
        guard character != " " else { return " " }
        let position = Double(column) / Double(max(columns, 1))
        let settled: Bool
        if phase < 0.35 {
            settled = phase / 0.35 > position
        } else if phase > 0.8 {
            settled = (phase - 0.8) / 0.2 < position
        } else {
            settled = true
        }
        if settled { return character }
        let seed = (row * 131 + column * 17 + Int(time * 18)) & 0x7FFF_FFFF
        return glyphs[seed % glyphs.count]
    }
}

/// Falling columns of glyphs in the theme's accent colour.
private struct MatrixScreensaver: View {
    let time: TimeInterval
    let accent: Color
    private static let glyphs = Array("ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄ0123456789LINPAD$#*+=<>")

    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = max(10, min(size.width, size.height) / 40)
            let columns = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            let trail = max(8, rows / 3)
            for column in 0..<columns {
                let speed = 6 + Double((column * 7919) % 9)
                let offset = Double((column * 104_729) % 97)
                let head = Int((time * speed + offset).truncatingRemainder(dividingBy: Double(rows + trail)))
                for step in 0..<trail {
                    let row = head - step
                    guard row >= 0, row < rows else { continue }
                    let seed = (column * 31 + row * 7 + Int(time * (step == 0 ? 12 : 3))) & 0x7FFF_FFFF
                    let glyph = String(Self.glyphs[seed % Self.glyphs.count])
                    let fade = 1 - Double(step) / Double(trail)
                    let color = step == 0 ? Color.white : accent.opacity(fade * 0.9)
                    context.draw(Text(glyph).font(.system(size: cell * 0.9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(color),
                                 at: CGPoint(x: CGFloat(column) * cell + cell / 2, y: CGFloat(row) * cell + cell / 2))
                }
            }
        }
    }
}

private struct ClockScreensaver: View {
    let date: Date
    let time: TimeInterval
    let size: CGSize
    let accent: Color

    var body: some View {
        let fontSize = max(18, min(size.width, size.height) * 0.22)
        VStack(spacing: fontSize * 0.08) {
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: fontSize, weight: .thin, design: .monospaced).monospacedDigit())
                .foregroundStyle(.white)
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: fontSize * 0.18, weight: .regular))
                .foregroundStyle(accent)
        }
        .fixedSize()
        .position(ScreensaverCanvas.drift(time, in: size, content: CGSize(width: fontSize * 3, height: fontSize * 1.4)))
    }
}

/// Settings › Screensaver & Lock.
struct IdleSettingsSection: View {
    let controller: DesktopController?
    @Environment(\.desktopTheme) private var theme
    @AppStorage(IdleSettings.styleKey) private var styleID = ScreensaverStyle.logo.rawValue
    @AppStorage(IdleSettings.screensaverMinutesKey) private var screensaverMinutes = 0
    @AppStorage(IdleSettings.lockMinutesKey) private var lockMinutes = 0
    @AppStorage(IdleSettings.keepAwakeKey) private var keepAwake = false

    var body: some View {
        SettingsSection(title: "Screensaver & Lock", symbol: "sparkles.tv") {
            HStack(alignment: .top, spacing: 16) {
                ScreensaverCanvas(style: ScreensaverStyle(rawValue: styleID) ?? .logo)
                    .frame(width: 200, height: 125)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier("settings.screensaver.preview")
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Screensaver", selection: $styleID) {
                        ForEach(ScreensaverStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.screensaver.style")
                    if let controller {
                        Button("Preview Full Screen") { controller.idle.showScreensaver() }
                            .foregroundStyle(theme.accent)
                            .accessibilityIdentifier("settings.screensaver.preview.start")
                    }
                }
            }
            SettingsRow(title: "Start screensaver after") {
                Picker("Start screensaver after", selection: $screensaverMinutes) {
                    ForEach(IdleSettings.screensaverChoices, id: \.self) { Text(IdleSettings.title(minutes: $0)).tag($0) }
                }
                .labelsHidden()
                .accessibilityIdentifier("settings.screensaver.after")
            }
            SettingsRow(title: "Lock screen after") {
                Picker("Lock screen after", selection: $lockMinutes) {
                    ForEach(IdleSettings.lockChoices, id: \.self) { Text(IdleSettings.title(minutes: $0)).tag($0) }
                }
                .labelsHidden()
                .accessibilityIdentifier("settings.autoLock.after")
            }
            SettingsRow(title: "Keep awake") {
                Toggle("Keep awake", isOn: $keepAwake)
                    .labelsHidden()
                    .tint(theme.accent)
                    .accessibilityIdentifier("settings.keepAwake")
            }
            Text("Idle means no touch, click or key press. Nothing starts during a screen recording or while a maximized window plays a video, or while Keep Awake is on. The iPad's own Auto-Lock still applies.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
