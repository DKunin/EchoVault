import SwiftUI

enum MiniPlayerPresentation: Equatable {
    case legacy
    case accessoryExpanded
    case accessoryInline
}

struct MiniPlayerView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let presentation: MiniPlayerPresentation
    let showNowPlaying: () -> Void

    var body: some View {
        Group {
            if presentation == .legacy {
                playerContent
                    .background(EchoVaultTheme.background)
                    .overlay(alignment: .top) {
                        Divider()
                    }
            } else {
                playerContent
                    .background(EchoVaultTheme.background)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var playerContent: some View {
        VStack(spacing: 0) {
            if !isInline, player.duration > 0 {
                ProgressView(value: player.elapsedTime, total: player.duration)
                    .tint(Color.accentColor)
                    .accessibilityHidden(true)
            }

            HStack(spacing: isInline ? 6 : 10) {
                nowPlayingButton

                Button(action: player.togglePlayPause) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(isInline ? .body : .title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                if showsNextButton {
                    Button(action: player.playNext) {
                        Image(systemName: "forward.fill")
                            .font(.body)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Next track")
                }
            }
            .padding(.horizontal, isInline ? 8 : 12)
            .padding(.vertical, isInline ? 0 : 6)
        }
    }

    private var nowPlayingButton: some View {
        Button(action: showNowPlaying) {
            HStack(spacing: isInline ? 8 : 11) {
                TrackArtworkView(
                    artworkURL: player.currentTrack?.artworkURL,
                    cornerRadius: isInline ? 6 : 8,
                    symbolSize: isInline ? 14 : 18
                )
                .frame(width: artworkSize, height: artworkSize)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !isInline, !dynamicTypeSize.isAccessibilitySize {
                        Text(player.currentTrack?.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Open Now Playing for \(player.currentTrack?.title ?? "track") by \(player.currentTrack?.artist ?? "Unknown Artist")"
        )
    }

    private var isInline: Bool {
        presentation == .accessoryInline
    }

    private var showsNextButton: Bool {
        !isInline && !dynamicTypeSize.isAccessibilitySize
    }

    private var artworkSize: CGFloat {
        isInline ? 30 : 42
    }
}

#if DEBUG
    #Preview("Mini player") {
        MiniPlayerView(presentation: .legacy, showNowPlaying: {})
            .environment(AudioPlayer.preview(track: .previewCached))
    }

    #Preview("Mini player — Accessibility") {
        MiniPlayerView(presentation: .legacy, showNowPlaying: {})
            .environment(AudioPlayer.preview(track: .previewCached))
            .environment(\.dynamicTypeSize, .accessibility3)
    }
#endif
