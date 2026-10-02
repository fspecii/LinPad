import Foundation
import MediaPlayer
import Observation
import UIKit

/// One MPRIS player (a Linux app that plays media) as playerctl reports it.
struct MediaPlayerSnapshot: Equatable, Sendable {
    enum Status: String, Sendable {
        case playing = "Playing", paused = "Paused", stopped = "Stopped"
    }

    var player: String
    var status: Status
    var title: String
    var artist: String
    var album: String
    /// `file://` (a guest path) or `http(s)://`; empty when the player has none.
    var artURL: String
    /// Seconds.
    var position: TimeInterval?
    var length: TimeInterval?

    var isPlaying: Bool { status == .playing }

    /// What to show when the player sends no title (a browser tab with a silent video).
    var displayTitle: String { title.isEmpty ? player.capitalized : title }
}

enum MediaCommand: String, Sendable {
    case playPause = "play-pause"
    case play, pause, next, previous
}

/// Talks to the guest's MPRIS players through `playerctl`.
enum MPRISCommand {
    /// Fields are joined with the ASCII unit separator, which no title or artist contains.
    static let separator: Character = "\u{1F}"
    static let fields = ["playerName", "status", "xesam:title", "xesam:artist", "xesam:album", "mpris:artUrl",
                         "position", "mpris:length"]

    static var format: String { fields.map { "{{\($0)}}" }.joined(separator: String(separator)) }

    /// Commands from the desktop do not inherit the GUI session's environment, so the bus
    /// address comes from the file the session hook writes, or else from the daemon's
    /// socket in /tmp (rootfs builds from before the hook).
    static let sessionBus = """
        if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
            DBUS_SESSION_BUS_ADDRESS=$(cat /tmp/ishwl-dbus-address 2>/dev/null)
            if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
                for s in /tmp/dbus-*; do [ -S "$s" ] && DBUS_SESSION_BUS_ADDRESS=unix:path=$s && break; done
            fi
            export DBUS_SESSION_BUS_ADDRESS
        fi
        """

    static var query: String {
        sessionBus + "\nplayerctl -a metadata --format " + ShellQuote.quote(format)
    }

    static func command(_ command: MediaCommand, player: String?) -> String {
        let target = player.map { "-p " + ShellQuote.quote($0) + " " } ?? ""
        return sessionBus + "\nplayerctl " + target + command.rawValue
    }

    /// One line per player; lines that are not in the expected shape (warnings) are skipped.
    static func parse(_ output: String) -> [MediaPlayerSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let values = line.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            guard values.count == fields.count, !values[0].isEmpty,
                  let status = MediaPlayerSnapshot.Status(rawValue: values[1]) else { return nil }
            func seconds(_ text: String) -> TimeInterval? {
                Double(text).flatMap { $0 > 0 ? $0 / 1_000_000 : nil }
            }
            return MediaPlayerSnapshot(player: values[0], status: status, title: values[2], artist: values[3],
                                       album: values[4], artURL: values[5], position: seconds(values[6]),
                                       length: seconds(values[7]))
        }
    }

    /// The player the controls drive: one that is playing, else one that is paused.
    static func preferred(_ players: [MediaPlayerSnapshot], current: String? = nil) -> MediaPlayerSnapshot? {
        if let playing = players.first(where: \.isPlaying) { return playing }
        if let current, let same = players.first(where: { $0.player == current }) { return same }
        return players.first { $0.status == .paused } ?? players.first
    }
}

/// Now Playing for Linux apps: the panel tile and widget read it, and the iPad's lock screen
/// and Control Center drive it through MPRemoteCommandCenter. The guest is polled only while
/// something that shows it is on screen (`start`/`stop` pairs).
@Observable @MainActor
final class NowPlayingCenter {
    private static let interval: Duration = .seconds(1)
    /// playerctl is missing or the bus is down: try again now and then, not every second.
    private static let unavailableInterval: Duration = .seconds(30)

    private(set) var player: MediaPlayerSnapshot?
    private(set) var artwork: UIImage?
    /// The guest has no playerctl (older rootfs); the tile says how to get it.
    private(set) var isPlayerctlMissing = false

    @ObservationIgnored private let host: any LinuxHost
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var artworkKey = ""
    @ObservationIgnored private var remoteIsRegistered = false
    @ObservationIgnored private var backgroundObserver: NSObjectProtocol?

    init(host: any LinuxHost) {
        self.host = host
    }

    func start() {
        users += 1
        guard users == 1 else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                do {
                    try await Task.sleep(for: isPlayerctlMissing ? Self.unavailableInterval : Self.interval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        let result = await host.run(MPRISCommand.query)
        isPlayerctlMissing = result.exitCode == 127
        let players = result.succeeded ? MPRISCommand.parse(result.stdout) : []
        let next = MPRISCommand.preferred(players, current: player?.player)
        if next != player { player = next }
        await updateArtwork(for: next)
        if next != nil { registerRemoteCommands() }
        publishNowPlayingInfo()
    }

    @discardableResult
    func perform(_ command: MediaCommand) -> Task<Void, Never>? {
        guard let current = player else { return nil }
        // Flip at once so the button answers the tap; the next poll confirms.
        switch command {
        case .playPause: player?.status = current.isPlaying ? .paused : .playing
        case .play: player?.status = .playing
        case .pause: player?.status = .paused
        case .next, .previous: break
        }
        publishNowPlayingInfo()
        return Task {
            _ = await host.run(MPRISCommand.command(command, player: current.player))
            await refresh()
        }
    }

    // MARK: Artwork

    private func updateArtwork(for player: MediaPlayerSnapshot?) async {
        let key = player?.artURL ?? ""
        guard key != artworkKey else { return }
        artworkKey = key
        guard let url = URL(string: key), !key.isEmpty else {
            artwork = nil
            return
        }
        let image = await loadArtwork(url)
        guard artworkKey == key else { return }
        artwork = image
    }

    private func loadArtwork(_ url: URL) async -> UIImage? {
        switch url.scheme {
        case "file":
            if let root = (host as? any LinuxGraphicsHost)?.guestRootURL {
                return UIImage(contentsOfFile: root.appendingPathComponent(url.path).path)
            }
            return (try? await host.readFile(url.path)).flatMap(UIImage.init(data:))
        case "http", "https":
            return (try? await URLSession.shared.data(from: url)).flatMap { UIImage(data: $0.0) }
        default:
            return nil
        }
    }

    // MARK: Lock screen and Control Center

    /// Registered once a Linux player has been seen, so an idle desktop never claims the
    /// iPad's Now Playing slot. The audio bridge's playback session is what makes iPadOS
    /// show these controls.
    private func registerRemoteCommands() {
        guard !remoteIsRegistered else { return }
        remoteIsRegistered = true
        let center = MPRemoteCommandCenter.shared()
        let bindings: [(MPRemoteCommand, MediaCommand)] = [
            (center.togglePlayPauseCommand, .playPause), (center.playCommand, .play),
            (center.pauseCommand, .pause), (center.nextTrackCommand, .next),
            (center.previousTrackCommand, .previous),
        ]
        for (remote, command) in bindings {
            remote.isEnabled = true
            remote.addTarget { [weak self] _ in
                Task { @MainActor in self?.perform(command) }
                return .success
            }
        }
        // Polling stops with the panel; one more look on the way to the lock screen keeps
        // what it shows current.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refresh() }
                }
            }
    }

    private func publishNowPlayingInfo() {
        guard remoteIsRegistered else { return }
        guard let player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: player.displayTitle,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        if !player.artist.isEmpty { info[MPMediaItemPropertyArtist] = player.artist }
        if !player.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = player.album }
        if let length = player.length { info[MPMediaItemPropertyPlaybackDuration] = length }
        if let position = player.position { info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
