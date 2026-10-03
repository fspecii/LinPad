import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DesktopKit

/// Fixture images drawn in code, so they are exact and need no files.
enum WallpaperFixtures {
    static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(context)
        return context.makeImage()!
    }

    static func cg(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// Navy to purple, smooth: a dark soft gradient.
    static let gradient = image(width: 640, height: 400) { context in
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [cg(0x0B1030), cg(0x3A1F6B)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 640, y: 400), options: [])
    }

    /// Pale sky to white: a light soft gradient.
    static let lightGradient = image(width: 640, height: 400) { context in
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [cg(0xCFE6FF), cg(0xF4F8FF)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 400), options: [])
    }

    /// Grey noise with a dark mean (deterministic LCG).
    static let nearMonochrome = image(width: 320, height: 200) { context in
        var seed: UInt32 = 12345
        for y in 0..<50 {
            for x in 0..<80 {
                seed = seed &* 1_103_515_245 &+ 12345
                let grey = 0.18 + Double(seed >> 16 & 0xFF) / 255 * 0.22
                context.setFillColor(CGColor(srgbRed: grey, green: grey, blue: grey * 1.02, alpha: 1))
                context.fill(CGRect(x: x * 4, y: y * 4, width: 4, height: 4))
            }
        }
    }

    /// Vivid blocks: mostly saturated orange, with red, green and blue patches on black.
    static let saturated = image(width: 400, height: 400) { context in
        context.setFillColor(cg(0x101010)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setFillColor(cg(0xFF7A00)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 220))
        context.setFillColor(cg(0xE0102A)); context.fill(CGRect(x: 0, y: 220, width: 120, height: 120))
        context.setFillColor(cg(0x16C060)); context.fill(CGRect(x: 140, y: 220, width: 120, height: 120))
        context.setFillColor(cg(0x2050F0)); context.fill(CGRect(x: 280, y: 220, width: 120, height: 120))
    }

    /// The classic teal desktop.
    static let retroTeal = image(width: 400, height: 300) { context in
        context.setFillColor(cg(0x008080)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(cg(0xC0C0C0)); context.fill(CGRect(x: 40, y: 40, width: 60, height: 40))
    }

    /// Photo-like texture: per-pixel noise over regions (deterministic LCG), so the
    /// neighbour-to-neighbour steps look like a detailed photo rather than a gradient.
    static func photo(regions: [(CGRect, UInt32)], noise: Double = 0.18) -> CGImage {
        image(width: 384, height: 240) { context in
            var seed: UInt32 = 987_654
            for (rect, hex) in regions {
                let r = Double(hex >> 16 & 0xFF) / 255, g = Double(hex >> 8 & 0xFF) / 255, b = Double(hex & 0xFF) / 255
                for y in Int(rect.minY)..<Int(rect.maxY) where y % 2 == 0 {
                    for x in Int(rect.minX)..<Int(rect.maxX) where x % 2 == 0 {
                        seed = seed &* 1_103_515_245 &+ 12345
                        let jitter = (Double(seed >> 16 & 0xFF) / 255 - 0.5) * noise
                        context.setFillColor(CGColor(srgbRed: min(max(r + jitter, 0), 1), green: min(max(g + jitter, 0), 1),
                                                     blue: min(max(b + jitter, 0), 1), alpha: 1))
                        context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                    }
                }
            }
        }
    }

    /// Green hills under a blue sky (CG's origin is bottom left).
    static let landscape = photo(regions: [(CGRect(x: 0, y: 0, width: 384, height: 130), 0x4A9A30),
                                           (CGRect(x: 0, y: 130, width: 384, height: 110), 0x5AA0E8)])
    /// A deep blue night city with warm windows.
    static let nightCity = photo(regions: [(CGRect(x: 0, y: 0, width: 384, height: 240), 0x0E1A40),
                                           (CGRect(x: 40, y: 0, width: 60, height: 120), 0x1A2550),
                                           (CGRect(x: 220, y: 0, width: 50, height: 90), 0x202A58)])
    /// Dark violet bokeh.
    static let darkViolet = photo(regions: [(CGRect(x: 0, y: 0, width: 384, height: 240), 0x2A0E3A),
                                            (CGRect(x: 100, y: 60, width: 120, height: 100), 0x6A1E80)])

    static var photos: [(String, URL)] {
        ["dunes", "peaks", "meadow", "nebula", "aurora-night"].compactMap { name in
            BuiltInWallpapers.url(for: "\(BuiltInWallpapers.prefix)\(name).jpg").map { (name, $0) }
        }
    }
}

final class WallpaperPaletteTests: XCTestCase {
    private func theme(_ image: CGImage, id: String = "from-wallpaper-test") throws -> (WallpaperAnalysis, ColorTheme) {
        let analysis = try XCTUnwrap(WallpaperAnalyzer.analyze(image: image))
        return (analysis, WallpaperPalette.theme(from: analysis, id: id, name: "From wallpaper — Test"))
    }

    private func allFixtures() throws -> [(String, WallpaperAnalysis)] {
        var list: [(String, WallpaperAnalysis)] = [
            ("gradient", WallpaperFixtures.gradient), ("light", WallpaperFixtures.lightGradient),
            ("mono", WallpaperFixtures.nearMonochrome), ("saturated", WallpaperFixtures.saturated),
            ("teal", WallpaperFixtures.retroTeal), ("landscape", WallpaperFixtures.landscape),
            ("night", WallpaperFixtures.nightCity), ("violet", WallpaperFixtures.darkViolet),
        ].map { ($0.0, WallpaperAnalyzer.analyze(image: $0.1)!) }
        for (name, url) in WallpaperFixtures.photos {
            list.append((name, try XCTUnwrap(WallpaperAnalyzer.analyze(url: url), name)))
        }
        XCTAssertGreaterThanOrEqual(list.count, 8, "built-in photos missing from the bundle")
        return list
    }

    func testOKLabRoundTripsAndKnownValues() {
        XCTAssertEqual(OKLab(RGB(red: 1, green: 1, blue: 1)).l, 1, accuracy: 1e-3)
        XCTAssertEqual(OKLab(RGB(red: 0, green: 0, blue: 0)).l, 0, accuracy: 1e-6)
        let red = OKLab(RGB(red: 1, green: 0, blue: 0))
        XCTAssertEqual(red.l, 0.628, accuracy: 0.002)
        XCTAssertEqual(red.hue, 29.2, accuracy: 0.5)
        for hex in ["#1a1b26", "#7aa2f7", "#f7768e", "#e0af68", "#ffffff", "#808080"] {
            let rgb = RGB(hex: hex)!
            XCTAssertEqual(OKLab(rgb).rgb.hex, hex)
        }
        // Out of gamut: chroma drops, hue stays.
        let vivid = OKLab(l: 0.7, chroma: 0.4, hue: 150)
        XCTAssertFalse(vivid.isInGamut)
        XCTAssertEqual(OKLab(vivid.rgb).hue, 150, accuracy: 2)
    }

    func testAnalysisAndThemeAreDeterministic() throws {
        for image in [WallpaperFixtures.gradient, WallpaperFixtures.saturated, WallpaperFixtures.nearMonochrome] {
            let (first, a) = try theme(image)
            let (second, b) = try theme(image)
            XCTAssertEqual(first, second)
            XCTAssertEqual(a, b)
        }
        let url = try XCTUnwrap(WallpaperFixtures.photos.first?.1)
        XCTAssertEqual(WallpaperAnalyzer.analyze(url: url), WallpaperAnalyzer.analyze(url: url))
    }

    func testEveryTextColourMeetsWCAG() throws {
        for (name, analysis) in try allFixtures() {
            let theme = WallpaperPalette.theme(from: analysis, id: "from-wallpaper-x", name: name)
            let bg = theme.backgroundRGB
            let ansi = theme.terminalColors
            XCTAssertEqual(ansi.count, 16, name)
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(theme.foregroundRGB, bg), 7, "\(name) foreground")
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(theme.accentRGB, bg), 4.5, "\(name) accent")
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(theme.foregroundRGB, theme.selectionRGB), 4.5, "\(name) selection")
            XCTAssertGreaterThanOrEqual(ColorContrast.ratio(ansi[8], bg), 3, "\(name) muted")
            for index in Array(1...6) + Array(9...15) {
                XCTAssertGreaterThanOrEqual(ColorContrast.ratio(ansi[index], bg), 4.5, "\(name) ansi \(index)")
            }
            XCTAssertEqual(ansi[0], bg, name)
            XCTAssertEqual(ansi[7], theme.foregroundRGB, name)
        }
    }

    func testAnsiColoursKeepTheirIdentity() throws {
        for (name, analysis) in try allFixtures() {
            let ansi = WallpaperPalette.theme(from: analysis, id: "x", name: name).terminalColors
            for (offset, hue) in WallpaperPalette.ansiHues.enumerated() {
                let lab = OKLab(ansi[offset + 1])
                XCTAssertLessThanOrEqual(OKLab.hueDistance(lab.hue, hue), 25, "\(name) ansi \(offset + 1) hue \(lab.hue)")
                XCTAssertGreaterThan(lab.chroma, 0.04, "\(name) ansi \(offset + 1) is grey")
            }
        }
    }

    func testLightOrDarkFollowsTheImage() throws {
        XCTAssertTrue(try theme(WallpaperFixtures.gradient).1.isDark)
        XCTAssertTrue(try theme(WallpaperFixtures.nearMonochrome).1.isDark)
        XCTAssertFalse(try theme(WallpaperFixtures.lightGradient).1.isDark)
        let (analysis, light) = try theme(WallpaperFixtures.lightGradient)
        XCTAssertGreaterThan(analysis.meanLightness, WallpaperAnalysis.darkThreshold)
        XCTAssertGreaterThan(OKLab(light.backgroundRGB).l, 0.9)
    }

    func testAccentIsTheMostSalientColourAndIgnoresExtremes() throws {
        let (analysis, saturated) = try theme(WallpaperFixtures.saturated)
        XCTAssertFalse(analysis.isNearMonochrome)
        let accent = OKLab(saturated.accentRGB)
        XCTAssertLessThan(OKLab.hueDistance(accent.hue, OKLab(RGB(hex: "#ff7a00")!).hue), 15, "accent hue \(accent.hue)")
        XCTAssertGreaterThan(accent.chroma, 0.12)

        let (mono, grey) = try theme(WallpaperFixtures.nearMonochrome)
        XCTAssertTrue(mono.isNearMonochrome)
        XCTAssertNil(mono.salientAccent)
        XCTAssertLessThan(OKLab(grey.accentRGB).chroma, 0.1, "a grey image gets a quiet accent")
    }

    func testThemeRoundTripsThroughColorsToml() throws {
        let (_, generated) = try theme(WallpaperFixtures.saturated)
        let read = try XCTUnwrap(ColorsToml.read(ColorsToml.write(generated), id: generated.id, name: generated.name))
        XCTAssertEqual(read.background, generated.background)
        XCTAssertEqual(read.foreground, generated.foreground)
        XCTAssertEqual(read.accent, generated.accent)
        XCTAssertEqual(read.ansi, generated.ansi)
        XCTAssertEqual(read.appearance, generated.appearance)
        XCTAssertEqual(ThemeFiles.files(for: generated).first { $0.0 == "theme.conf" }?.1,
                       Data("name=From wallpaper — Test\n".utf8))
    }

    func testFourKImageIsAnalysedWellUnder300ms() throws {
        let big = WallpaperFixtures.image(width: 3840, height: 2160) { context in
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: [WallpaperFixtures.cg(0x203050), WallpaperFixtures.cg(0xE08040)] as CFArray,
                                      locations: [0, 1])!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 3840, y: 2160), options: [])
            for index in 0..<400 {
                context.setFillColor(WallpaperFixtures.cg(UInt32(index * 2_654_435_761 & 0xFFFFFF)))
                context.fillEllipse(in: CGRect(x: index * 37 % 3800, y: index * 53 % 2100, width: 40, height: 40))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wallmatch-4k-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, big, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var best = Double.infinity
        for _ in 0..<3 {
            let start = Date()
            let analysis = WallpaperAnalyzer.analyze(url: url)
            let theme = analysis.map { WallpaperPalette.theme(from: $0, id: "x", name: "x") }
            best = min(best, Date().timeIntervalSince(start))
            XCTAssertNotNil(theme)
        }
        print("wallmatch: 4K analysis + palette \(Int(best * 1000)) ms")
        XCTAssertLessThan(best, 0.3)
    }
}

final class WallpaperMatchingTests: XCTestCase {
    func testClosestThemeIsFoundAndGeneratedOnesAreSkipped() throws {
        let themes = ColorTheme.builtIn
        let tokyo = try XCTUnwrap(themes.first { $0.id == "tokyo-night" })
        var twin = tokyo
        twin.id = "from-wallpaper-twin"
        let closest = try XCTUnwrap(WallpaperMatching.closest(to: twin, in: themes + [twin]))
        XCTAssertEqual(closest.theme.id, "tokyo-night")
        XCTAssertEqual(closest.distance, 0, accuracy: 1e-9)

        var nudged = tokyo
        nudged.id = "from-wallpaper-nudged"
        nudged.background = "#1d1e2a"
        XCTAssertEqual(WallpaperMatching.closest(to: nudged, in: themes)?.theme.id, "tokyo-night")
        XCTAssertLessThan(WallpaperMatching.distance(nudged, tokyo), WallpaperMatching.closeDistance)
        let light = try XCTUnwrap(themes.first { !$0.isDark })
        XCTAssertGreaterThan(WallpaperMatching.distance(tokyo, light), 0.1)
    }

    func testIconPackRuleTable() {
        XCTAssertEqual(WallpaperMatching.iconPack(accent: RGB(hex: "#7aa2f7")!, installed: []), "Tela-circle")
        XCTAssertEqual(WallpaperMatching.iconPack(accent: RGB(hex: "#888888")!, installed: []), "Colloid")
        XCTAssertEqual(WallpaperMatching.iconPack(accent: RGB(hex: "#ff7a00")!, installed: []), "Numix-Circle")
        XCTAssertEqual(WallpaperMatching.iconPack(accent: RGB(hex: "#30c060")!, installed: []), "Qogir")
        XCTAssertEqual(WallpaperMatching.iconPack(accent: RGB(hex: "#30c060")!, installed: ["Tela-circle-green", "Papirus"]),
                       "Tela-circle-green")
        XCTAssertEqual(WallpaperMatching.iconPack(accent: RGB(hex: "#b070f0")!, installed: []), "Tela-circle")
        XCTAssertEqual(WallpaperMatching.iconPack(accent: RGB(hex: "#b070f0")!, installed: ["Tela-circle-purple"]),
                       "Tela-circle-purple")
        XCTAssertEqual(WallpaperMatching.iconPack(accent: RGB(hex: "#7aa2f7")!, installed: ["Adwaita", "Papirus"]), "Papirus")
    }

    func testStyleRuleTable() throws {
        func style(_ image: CGImage) -> DesktopStyle? {
            WallpaperAnalyzer.analyze(image: image).flatMap(WallpaperMatching.style(for:))?.style
        }
        XCTAssertEqual(style(WallpaperFixtures.gradient), .macos)
        XCTAssertEqual(style(WallpaperFixtures.lightGradient), .aqua)
        XCTAssertEqual(style(WallpaperFixtures.nearMonochrome), .tiler)
        XCTAssertEqual(style(WallpaperFixtures.retroTeal), .classic)
        XCTAssertEqual(style(WallpaperFixtures.landscape), .luna)
        XCTAssertEqual(style(WallpaperFixtures.nightCity), .aeronight)
        XCTAssertEqual(style(WallpaperFixtures.darkViolet), .berry)
        for (name, image) in [("gradient", WallpaperFixtures.gradient), ("light", WallpaperFixtures.lightGradient),
                              ("mono", WallpaperFixtures.nearMonochrome), ("teal", WallpaperFixtures.retroTeal),
                              ("landscape", WallpaperFixtures.landscape), ("night", WallpaperFixtures.nightCity),
                              ("violet", WallpaperFixtures.darkViolet), ("saturated", WallpaperFixtures.saturated)] {
            let analysis = try XCTUnwrap(WallpaperAnalyzer.analyze(image: image))
            print("wallmatch: \(name) dark=\(analysis.prefersDark) L=\(String(format: "%.2f", analysis.meanLightness)) "
                  + "C=\(String(format: "%.3f", analysis.colorfulness)) edges=\(String(format: "%.4f", analysis.edgeDensity)) "
                  + "flat=\(String(format: "%.2f", analysis.flatness)) hue=\(Int(analysis.dominant.color.hue))")
        }
        for (name, url) in WallpaperFixtures.photos {
            let analysis = try XCTUnwrap(WallpaperAnalyzer.analyze(url: url))
            let suggestion = WallpaperMatching.style(for: analysis)
            print("wallmatch: \(name) dark=\(analysis.prefersDark) L=\(String(format: "%.2f", analysis.meanLightness)) "
                  + "C=\(String(format: "%.3f", analysis.colorfulness)) edges=\(String(format: "%.4f", analysis.edgeDensity)) "
                  + "flat=\(String(format: "%.2f", analysis.flatness)) → \(suggestion?.style.rawValue ?? "keep")")
        }
    }

    func testGeneratedThemesAreNamedPerWallpaperAndEditableInPlace() throws {
        let id = WallpaperMatchNaming.id(for: "builtin-dunes")
        XCTAssertTrue(WallpaperMatchNaming.isGenerated(id))
        XCTAssertEqual(WallpaperMatchNaming.themeName(for: "builtin-dunes"), "From wallpaper — Dunes")
        XCTAssertEqual(WallpaperMatchNaming.themeName(for: "wallhaven-abc123"), "From wallpaper — Wallhaven abc123")
        XCTAssertEqual(WallpaperMatchNaming.id(for: "builtin-dunes"), WallpaperMatchNaming.id(for: "builtin-dunes"))
        XCTAssertNotEqual(id, WallpaperMatchNaming.id(for: "builtin-peaks"))
        // The editor derives the id from the name: saving an unchanged match overwrites it.
        let analysis = try XCTUnwrap(WallpaperAnalyzer.analyze(image: WallpaperFixtures.gradient))
        let generated = WallpaperPalette.theme(from: analysis, id: id, name: WallpaperMatchNaming.themeName(for: "builtin-dunes"))
        XCTAssertEqual(ThemeDraft(theme: generated, name: generated.name).id, generated.id)
    }

    func testProposalChoices() throws {
        let analysis = try XCTUnwrap(WallpaperAnalyzer.analyze(image: WallpaperFixtures.saturated))
        var proposal = WallpaperMatchProposal.make(analysis: analysis, source: .image("builtin-dunes"),
                                                   wallpaperID: "builtin-dunes", themes: ColorTheme.builtIn, installedPacks: [])
        XCTAssertFalse(proposal.includesStyle, "layout changes are opt-in")
        XCTAssertEqual(proposal.chosenTheme.iconTheme, proposal.iconPack)
        proposal.includesIconPack = false
        XCTAssertNil(proposal.chosenTheme.iconTheme)
        proposal.usesClosest = true
        XCTAssertEqual(proposal.chosenTheme.id, proposal.closest?.theme.id)
    }

    @MainActor
    func testSettingAWallpaperOffersAMatch() async throws {
        let keys = [WallpaperStore.settingsKey, WallpaperMatchModel.autoMatchKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set(false, forKey: WallpaperMatchModel.autoMatchKey)
        let controller = DesktopController(host: MockLinuxHost(latency: .zero), apps: BuiltinApps.all())
        controller.wallpapers.set(.image("builtin-peaks"), target: .both, workspace: 0)
        controller.wallpapers.set(.image("builtin-dunes"), target: .both, workspace: 0)
        for _ in 0..<150 where controller.wallpaperMatch.prompt?.wallpaperID != "builtin-dunes" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.wallpaperMatch.prompt?.wallpaperID, "builtin-dunes")
        XCTAssertEqual(controller.colorThemes.currentID, UserDefaults.standard.string(forKey: ColorThemeStore.storageKey) ?? "",
                       "nothing is applied until the user taps Apply")
    }

    @MainActor
    func testApplyingAMatchWritesAUserThemeAndUndoRestores() async throws {
        let keys = [ColorThemeStore.storageKey, WallpaperStore.settingsKey, WallpaperMatchModel.autoMatchKey,
                    LinuxDeviceInfo.colorThemeNameKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set("", forKey: ColorThemeStore.storageKey)

        let host = MockLinuxHost(latency: .zero)
        let controller = DesktopController(host: host, apps: BuiltinApps.all())
        let source = WallpaperSource.image("builtin-dunes")
        let made = await controller.makeWallpaperMatch(for: source)
        let proposal = try XCTUnwrap(made)
        controller.applyWallpaperMatch(proposal)
        let id = proposal.generated.id
        for _ in 0..<100 where controller.colorThemes.currentID != id { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(controller.colorThemes.currentID, id)
        XCTAssertEqual(controller.colorThemes.theme(id)?.name, "From wallpaper — Dunes")
        let toml = try await host.readFile("/root/.config/linpad/colors/\(id)/colors.toml")
        XCTAssertEqual(ColorsToml.read(String(decoding: toml, as: UTF8.self), id: id, name: "x")?.accent,
                       proposal.generated.accent)
        let icons = try await host.readFile("/root/.config/linpad/colors/\(id)/icons.theme")
        XCTAssertEqual(String(decoding: icons, as: UTF8.self), "\(proposal.iconPack)\n")

        let undo = try XCTUnwrap(controller.toasts.last?.action)
        undo.perform()
        XCTAssertEqual(controller.colorThemes.currentID, "")
    }
}
