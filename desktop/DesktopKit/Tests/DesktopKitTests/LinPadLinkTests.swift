import XCTest
@testable import DesktopKit

final class LinPadLinkTests: XCTestCase {
    private func parse(_ text: String) -> LinPadLink? {
        URL(string: text).flatMap(LinPadLink.parse)
    }

    private let toml = """
        mode = "dark"
        accent = "#7aa2f7"
        background = "#1a1b26"
        foreground = "#a9b1d6"
        """

    func testThemeInstall() {
        XCTAssertEqual(parse("linpad://theme/install?url=https://github.com/someone/omarchy-nord-theme"),
                       .installTheme(gitURL: "https://github.com/someone/omarchy-nord-theme"))
        XCTAssertEqual(parse("LINPAD://theme/install?url=https%3A%2F%2Fgithub.com%2Fa%2Fb"), .installTheme(gitURL: "https://github.com/a/b"))
        XCTAssertEqual(parse("linpad://theme/install?url=git@github.com:a/b.git"), .installTheme(gitURL: "git@github.com:a/b.git"))
        for bad in ["linpad://theme/install", "linpad://theme/install?url=", "linpad://theme/install?url=--upload-pack=x",
                    "linpad://theme/install?url=file:///etc", "linpad://theme/install?url=ext::sh%20-c%20x",
                    "linpad://theme/install?url=https://a/b%20c", "https://theme/install?url=https://github.com/a/b"] {
            XCTAssertNil(parse(bad), bad)
        }
    }

    func testThemeImportRoundTrips() throws {
        let link = LinPadLink.importTheme(name: "Night & Day + 1", colorsToml: toml)
        let url = link.url
        XCTAssertFalse(url.absoluteString.contains("+1"), "query values are fully escaped: \(url)")
        XCTAssertEqual(LinPadLink.parse(url), link)
        XCTAssertNil(parse("linpad://theme/import?name=x&colors=" + Base64URL.encode(Data("not a theme".utf8))))
        XCTAssertNil(parse("linpad://theme/import?name=x&colors=***"))
        let unnamed = try XCTUnwrap(parse("linpad://theme/import?colors=" + Base64URL.encode(Data(toml.utf8))))
        XCTAssertEqual(unnamed, .importTheme(name: "Shared Theme", colorsToml: toml))
    }

    func testShareLinkPrefersTheRepository() throws {
        var theme = try XCTUnwrap(ColorsToml.read(toml, id: "night", name: "Night"))
        if case .importTheme(let name, _) = LinPadLink.share(theme) { XCTAssertEqual(name, "Night") } else { XCTFail() }
        theme.source = "https://github.com/someone/night-theme"
        XCTAssertEqual(LinPadLink.share(theme), .installTheme(gitURL: "https://github.com/someone/night-theme"))
    }

    func testLookRoundTripsAndIsSanitized() throws {
        var styling = DesktopStyling()
        styling.cornerRadius = 500
        styling.panelOpacity = 0
        styling.fontScale = 3
        styling.linuxMonoFont = "--evil"
        styling.linuxUIFont = "Inter"
        styling.cursorSize = 7
        let look = DesktopLook(id: "user-1", name: "  Tokyo\nDesk ", styleID: "macos", colorThemeID: "tokyo-night",
                               styling: styling, wallpaperQuery: "city; rm -rf /", appearanceID: "bogus", isBuiltIn: true)
        let url = LinPadLink.applyLook(look).url
        XCTAssertTrue(url.absoluteString.hasPrefix("linpad://look/"))
        guard case .applyLook(let parsed)? = LinPadLink.parse(url) else { return XCTFail("\(url)") }
        XCTAssertEqual(parsed.name, "TokyoDesk")
        XCTAssertTrue(parsed.id.hasPrefix("shared-"))
        XCTAssertFalse(parsed.isBuiltIn)
        XCTAssertEqual(parsed.styleID, "macos")
        XCTAssertEqual(parsed.colorThemeID, "tokyo-night")
        XCTAssertNil(parsed.appearanceID)
        XCTAssertEqual(parsed.wallpaperQuery, "city rm rf ")
        XCTAssertEqual(parsed.styling.cornerRadius, 40)
        XCTAssertEqual(parsed.styling.panelOpacity, 0.3)
        XCTAssertEqual(parsed.styling.fontScale, 1.2)
        XCTAssertNil(parsed.styling.linuxMonoFont, "only fonts the image ships")
        XCTAssertEqual(parsed.styling.linuxUIFont, "Inter")
        XCTAssertNil(parsed.styling.cursorSize)

        var hostile = look
        hostile.colorThemeID = "-x; reboot"
        XCTAssertNil(LinPadLink.parse(LinPadLink.applyLook(hostile).url))
        XCTAssertNil(parse("linpad://look/"))
        XCTAssertNil(parse("linpad://look/e30"), "{} is not a Look")
        XCTAssertNil(parse("linpad://look/" + String(repeating: "A", count: 40_000)))
    }

    func testAppInstallAndOpen() {
        XCTAssertEqual(parse("linpad://app/install?id=claude-code"), .installApp(id: "claude-code"))
        XCTAssertEqual(LinPadLink.parse(LinPadLink.installApp(id: "vscode").url), .installApp(id: "vscode"))
        for bad in ["linpad://app/install", "linpad://app/install?id=../x", "linpad://app/install?id=A", "linpad://app/remove?id=vlc",
                    "linpad://app/install?id=-rf", "linpad://nothing/here"] {
            XCTAssertNil(parse(bad), bad)
        }
        XCTAssertEqual(parse("linpad://"), .open)
        XCTAssertEqual(parse("linpad://open"), .open)
    }

    func testBase64URL() {
        let data = Data([0xfb, 0xff, 0xfe, 0x00, 0x41])
        let text = Base64URL.encode(data)
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(Base64URL.decode(text), data)
        XCTAssertNil(Base64URL.decode("a b"))
    }

    @MainActor
    func testInboxKeepsTheLinkForTheDesktop() {
        let inbox = LinPadLinkInbox()
        XCTAssertFalse(inbox.receive(URL(string: "https://example.com")!))
        XCTAssertTrue(inbox.receive(URL(string: "linpad://")!))
        XCTAssertNil(inbox.pending, "a bare link only opens the app")
        XCTAssertTrue(inbox.receive(URL(string: "linpad://app/install?id=vlc")!))
        XCTAssertEqual(inbox.pending?.link, .installApp(id: "vlc"))
        XCTAssertTrue(inbox.receive(URL(string: "linpad://app/install?id=BAD")!))
        XCTAssertNotNil(inbox.rejected)
    }
}

final class FastModeCheckTests: XCTestCase {
    func testChecklist() {
        let ready = FastModeCheck.evaluate(jitCompiledIn: true, isSimulator: false, hasGetTaskAllow: true, stikDebugInstalled: true,
                                           localDevVPNInstalled: true, vpnLooksConnected: true, status: .on(newProgramsOnly: false),
                                           engine: .nativeJIT)
        XCTAssertEqual(ready.map(\.id), ["build", "get-task-allow", "stikdebug", "pairing", "localdevvpn", "vpn", "result"])
        XCTAssertEqual(ready.filter { $0.state == .missing }, [])

        let fresh = FastModeCheck.evaluate(jitCompiledIn: true, isSimulator: false, hasGetTaskAllow: false, stikDebugInstalled: false,
                                           localDevVPNInstalled: false, vpnLooksConnected: false, status: .failed("StikDebug did not open."),
                                           engine: .compatibility)
        XCTAssertEqual(fresh.filter { $0.state == .missing }.map(\.id), ["get-task-allow", "stikdebug", "localdevvpn", "result"])
        XCTAssertEqual(fresh.first { $0.id == "vpn" }?.state, .info, "no VPN app: connecting is not the next step")
        XCTAssertEqual(fresh.last?.detail, "StikDebug did not open.")

        let simulator = FastModeCheck.evaluate(jitCompiledIn: false, isSimulator: true, hasGetTaskAllow: nil, stikDebugInstalled: false,
                                               localDevVPNInstalled: false, vpnLooksConnected: false, status: .idle, engine: nil)
        XCTAssertEqual(simulator.first?.state, .missing)
        XCTAssertTrue(simulator.contains { $0.id == "device" })
        XCTAssertEqual(simulator.first { $0.id == "get-task-allow" }?.state, .info)
    }
}
