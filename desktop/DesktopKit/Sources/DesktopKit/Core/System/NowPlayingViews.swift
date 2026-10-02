import SwiftUI

/// Artwork, title and artist with previous / play-pause / next, for Quick Settings and the
/// Now Playing widget. Polls the guest while it is on screen.
struct NowPlayingCard: View {
    let center: NowPlayingCenter
    var isCompact = false
    @Environment(\.desktopTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(center.player?.displayTitle ?? "Not Playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("nowPlaying.title")
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(isCompact ? 1 : 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                control("backward.fill", label: "Previous", command: .previous)
                control(center.player?.isPlaying == true ? "pause.fill" : "play.fill",
                        label: center.player?.isPlaying == true ? "Pause" : "Play", command: .playPause, size: 18)
                control("forward.fill", label: "Next", command: .next)
            }
            .disabled(center.player == nil)
            .opacity(center.player == nil ? 0.4 : 1)
        }
        .foregroundStyle(theme.primaryText)
        .onAppear { center.start() }
        .onDisappear { center.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlaying")
    }

    private var subtitle: String {
        if let player = center.player {
            let parts = [player.artist, player.album].filter { !$0.isEmpty }
            return parts.isEmpty ? player.player.capitalized : parts.joined(separator: " — ")
        }
        return center.isPlayerctlMissing ? "Media controls need playerctl (apk add playerctl)"
            : "Music and video from Linux apps show here"
    }

    private var artwork: some View {
        let side: CGFloat = isCompact ? 40 : 46
        return Group {
            if let image = center.artwork {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    theme.accent.opacity(0.18)
                    Image(systemName: "music.note").font(.system(size: side * 0.4, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private func control(_ symbol: String, label: String, command: MediaCommand, size: CGFloat = 14) -> some View {
        Button { center.perform(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
        .accessibilityIdentifier("nowPlaying.\(command.rawValue)")
    }
}
