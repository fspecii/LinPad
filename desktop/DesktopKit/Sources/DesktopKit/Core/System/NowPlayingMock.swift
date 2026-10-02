import Foundation

/// playerctl for MockLinuxHost: one player with a short playlist, so the Now Playing tile
/// and widget can be exercised without the emulator.
@MainActor
final class MockMediaPlayer {
    static let shared = MockMediaPlayer()

    private let tracks = [
        ("Weightless", "Marconi Union", "Ambient Transmissions"),
        ("Midnight City", "M83", "Hurry Up, We're Dreaming"),
        ("Intro", "The xx", "xx"),
    ]
    private var index = 0
    private var isPlaying = true
    private let started = Date()

    func reply(to command: String) -> CommandResult? {
        guard command.contains("playerctl ") else { return nil }
        if command.contains(" metadata ") { return CommandResult(stdout: metadata()) }
        if command.hasSuffix("play-pause") {
            isPlaying.toggle()
        } else if command.hasSuffix(" play") {
            isPlaying = true
        } else if command.hasSuffix(" pause") {
            isPlaying = false
        } else if command.hasSuffix(" next") {
            index = (index + 1) % tracks.count
        } else if command.hasSuffix(" previous") {
            index = (index + tracks.count - 1) % tracks.count
        }
        return CommandResult(stdout: "")
    }

    private func metadata() -> String {
        let (title, artist, album) = tracks[index]
        let position = Int(Date().timeIntervalSince(started) * 1_000_000) % 240_000_000
        let values = ["vlc", isPlaying ? "Playing" : "Paused", title, artist, album, "", "\(position)", "240000000"]
        return values.joined(separator: String(MPRISCommand.separator)) + "\n"
    }
}
