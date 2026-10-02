import XCTest
@testable import DesktopKit

private func fixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures").appendingPathComponent(name)
    return try Data(contentsOf: url)
}

final class WeatherParsingTests: XCTestCase {
    func testForecastFixtureParses() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let report = try OpenMeteo.parseForecast(fixture("open-meteo-forecast.json"), place: "London", now: now)
        XCTAssertEqual(report.place, "London")
        XCTAssertEqual(report.temperature, 15.3)
        XCTAssertEqual(report.code, 61)
        XCTAssertTrue(report.isDay)
        XCTAssertEqual(report.unit, "°C")
        XCTAssertEqual(report.days.count, 4)
        XCTAssertEqual(report.days[1], WeatherReport.Day(date: "2026-10-03", code: 3, high: 17.4, low: 10.2))
        XCTAssertEqual(report.updated, now)
        XCTAssertEqual(report.condition.title, "Rain")
        XCTAssertEqual(report.condition.symbol(isDay: true), "cloud.rain.fill")
    }

    func testGeocodingFixtureParses() throws {
        let place = try XCTUnwrap(OpenMeteo.parseGeocoding(fixture("open-meteo-geocoding.json")))
        XCTAssertEqual(place.name, "London")
        XCTAssertEqual(place.latitude, 51.50853, accuracy: 0.00001)
        XCTAssertNil(try OpenMeteo.parseGeocoding(Data(#"{"generationtime_ms":0.2}"#.utf8)))
    }

    func testClearSkiesUseTheMoonAtNight() {
        XCTAssertEqual(WeatherCondition(code: 0).symbol(isDay: false), "moon.stars.fill")
        XCTAssertEqual(WeatherCondition(code: 95).title, "Thunderstorm")
    }

    func testForecastURLAsksForFahrenheitOnlyWhenWanted() {
        let place = OpenMeteo.Place(name: "Austin", latitude: 30.27, longitude: -97.74)
        XCTAssertTrue(OpenMeteo.forecastURL(for: place, fahrenheit: true).absoluteString.contains("temperature_unit=fahrenheit"))
        XCTAssertFalse(OpenMeteo.forecastURL(for: place, fahrenheit: false).absoluteString.contains("temperature_unit"))
    }
}

final class MPRISParsingTests: XCTestCase {
    func testPlayerctlFixtureParses() throws {
        let output = String(decoding: try fixture("playerctl-metadata.txt"), as: UTF8.self)
        let players = MPRISCommand.parse(output)
        XCTAssertEqual(players.map(\.player), ["vlc", "firefox.instance_1_42", "mpv"])

        let vlc = players[0]
        XCTAssertEqual(vlc.status, .paused)
        XCTAssertEqual(vlc.title, "Intro")
        XCTAssertEqual(vlc.artist, "The xx")
        XCTAssertEqual(vlc.artURL, "file:///root/.cache/vlc/art/intro.jpg")
        XCTAssertEqual(vlc.position ?? 0, 61, accuracy: 0.001)
        XCTAssertEqual(vlc.length ?? 0, 127, accuracy: 0.001)

        let firefox = players[1]
        XCTAssertEqual(firefox.title, "Lofi beats, to relax to")
        XCTAssertNil(firefox.length)
        XCTAssertEqual(players[2].displayTitle, "Mpv")
    }

    func testThePlayingPlayerIsPreferredThenTheCurrentOne() throws {
        let players = MPRISCommand.parse(String(decoding: try fixture("playerctl-metadata.txt"), as: UTF8.self))
        XCTAssertEqual(MPRISCommand.preferred(players)?.player, "firefox.instance_1_42")
        let paused = players.filter { !$0.isPlaying }
        XCTAssertEqual(MPRISCommand.preferred(paused, current: "mpv")?.player, "mpv")
        XCTAssertEqual(MPRISCommand.preferred(paused)?.player, "vlc")
        XCTAssertNil(MPRISCommand.preferred([]))
    }

    func testCommandsQuoteThePlayerName() {
        let command = MPRISCommand.command(.next, player: "it's")
        XCTAssertTrue(command.hasSuffix("playerctl -p 'it'\\''s' next"))
        XCTAssertTrue(MPRISCommand.query.contains("playerctl -a metadata --format"))
    }

    @MainActor
    func testCenterDrivesTheMockPlayer() async {
        let center = NowPlayingCenter(host: MockLinuxHost(latency: .zero))
        await center.refresh()
        XCTAssertEqual(center.player?.player, "vlc")
        let wasPlaying = center.player?.isPlaying ?? false
        let toggle = center.perform(.playPause)
        XCTAssertEqual(center.player?.isPlaying, !wasPlaying, "the button answers before the guest does")
        await toggle?.value
        XCTAssertEqual(center.player?.isPlaying, !wasPlaying)
        await center.perform(.next)?.value
        XCTAssertEqual(center.player?.title, "Midnight City")
        await center.perform(.previous)?.value
        await center.perform(.playPause)?.value
    }
}
