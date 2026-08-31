import SwiftUI

struct TrackRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let track: AudioTrack
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                TrackArtworkView(artworkURL: track.artworkURL)
                    .frame(width: 50, height: 50)
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent && isPlaying {
                            Image(systemName: "waveform")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Color.accentColor, in: Circle())
                                .offset(x: 3, y: 3)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }

                Spacer(minLength: 8)

                if isCurrent && isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(isCurrent ? (isPlaying ? "Pause" : "Resume") : "Play") \(track.title) by \(track.artist)"
        )
        .accessibilityValue(
            isCurrent ? (isPlaying ? "Playing" : "Paused") : "Not playing"
        )
    }
}

#Preview("Track row") {
    List {
        TrackRow(
            track: AudioTrack(
                title: "Northern Lights",
                artist: "Aurora Lane",
                albumTitle: "Night Drive",
                filename: "Northern Lights.m4a",
                localURL: URL(fileURLWithPath: "/tmp/Northern Lights.m4a"),
                origin: .webDAV,
                remoteURL: URL(string: "https://example.com/music/Northern%20Lights.m4a")
            ),
            isCurrent: true,
            isPlaying: true,
            action: {}
        )
    }
}
