import XCTest
@testable import DesktopKit

final class FirefoxRenderingTests: XCTestCase {
    func testRewritesTheNormalColumnAndKeepsFullscreenAtOne() {
        let shipped = "# PROGRAM SCALE [FULLSCREEN]\nfirefox-esr 2 1\ngimp 1\n"
        XCTAssertEqual(FirefoxRendering.smoothVideo.rewrite(shipped), "# PROGRAM SCALE [FULLSCREEN]\nfirefox-esr 1 1\ngimp 1\n")
        XCTAssertEqual(FirefoxRendering.sharpText.rewrite("firefox-esr 1 1\n"), "firefox-esr 2 1\n")
    }

    func testAddsTheLineWhenMissing() {
        XCTAssertEqual(FirefoxRendering.smoothVideo.rewrite(""), "firefox-esr 1 1\n")
        XCTAssertEqual(FirefoxRendering.smoothVideo.rewrite("gimp 1"), "gimp 1\nfirefox-esr 1 1\n")
    }

    func testCollapsesDuplicatesAndIgnoresComments() {
        let contents = "# firefox-esr 3\nfirefox-esr 2\nfirefox-esr-beta 1\nfirefox-esr 1 1\n"
        XCTAssertEqual(FirefoxRendering.sharpText.rewrite(contents), "# firefox-esr 3\nfirefox-esr 2 1\nfirefox-esr-beta 1\n")
    }

    func testReadsTheModeAsIshwlDoes() {
        XCTAssertEqual(FirefoxRendering.current(in: ""), .sharpText)
        XCTAssertEqual(FirefoxRendering.current(in: "firefox-esr 2 1\n"), .sharpText)
        XCTAssertEqual(FirefoxRendering.current(in: "firefox-esr 1\n"), .smoothVideo)
        XCTAssertEqual(FirefoxRendering.current(in: "firefox-esr 1 1\nfirefox-esr  2\n"), .sharpText, "the last line wins")
        XCTAssertEqual(FirefoxRendering.current(in: "#firefox-esr 1\n"), .sharpText)
    }

    func testRoundTrip() {
        for mode in FirefoxRendering.allCases {
            XCTAssertEqual(FirefoxRendering.current(in: mode.rewrite("firefox-esr 2 1\n")), mode)
        }
    }

    @MainActor
    func testApplyWritesThroughTheHost() async throws {
        let host = MockLinuxHost(latency: .zero)
        try await FirefoxRendering.smoothVideo.apply(to: host)
        let written = String(decoding: try await host.readFile(FirefoxRendering.path), as: UTF8.self)
        XCTAssertTrue(written.contains("firefox-esr 1 1"), written)
        let mode = await FirefoxRendering.load(from: host)
        XCTAssertEqual(mode, .smoothVideo)
    }
}
