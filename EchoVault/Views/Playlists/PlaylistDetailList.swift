import SwiftUI

struct PlaylistDetailList: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let playlist: MusicPlaylist
    let resolvedTracks: [AudioTrack]
    let playInOrder: () -> Void
    let playShuffled: () -> Void
    let removeItem: (PlaylistItem.ID) -> Void
    let removeItems: (IndexSet) -> Void
    let moveItems: (IndexSet, Int) -> Void

    var body: some View {
        List {
            PlaylistHeaderSection(
                playlist: playlist,
                trackCount: resolvedTracks.count
            )
            .listRowBackground(Color.clear)

            Section {
                PlaylistPlaybackButtons(
                    isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
                    isDisabled: resolvedTracks.isEmpty,
                    playInOrder: playInOrder,
                    playShuffled: playShuffled
                )
            }
            .listRowBackground(EchoVaultTheme.background)

            if playlist.items.isEmpty {
                ContentUnavailableView {
                    Label("Empty playlist", systemImage: "music.note.list")
                } description: {
                    Text("Use Add Music to include folders or individual tracks.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section("Contents") {
                    ForEach(playlist.items) { item in
                        PlaylistItemRow(
                            item: item,
                            track: track(for: item),
                            folder: folder(for: item),
                            playbackTracks: resolvedTracks,
                            remove: { removeItem(item.id) }
                        )
                    }
                    .onDelete(perform: removeItems)
                    .onMove(perform: moveItems)
                }
                .listRowBackground(EchoVaultTheme.background)
            }
        }
        .listStyle(.insetGrouped)
        .echoVaultBlackSurface()
    }

    private func track(for item: PlaylistItem) -> AudioTrack? {
        guard item.kind == .track else {
            return nil
        }
        return library.tracks.first { $0.id == item.referenceID }
    }

    private func folder(for item: PlaylistItem) -> MusicFolder? {
        guard item.kind == .folder else {
            return nil
        }
        return library.folders.first { $0.id == item.referenceID }
    }
}

private struct PlaylistHeaderSection: View {
    let playlist: MusicPlaylist
    let trackCount: Int

    var body: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 180, height: 180)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 24))

                VStack(spacing: 4) {
                    Text(playlist.name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Playlist")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(trackCount) \(trackCount == 1 ? "track" : "tracks")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

private struct PlaylistPlaybackButtons: View {
    let isAccessibilitySize: Bool
    let isDisabled: Bool
    let playInOrder: () -> Void
    let playShuffled: () -> Void

    var body: some View {
        Group {
            if isAccessibilitySize {
                VStack(spacing: 10) {
                    buttons
                }
            } else {
                HStack(spacing: 12) {
                    buttons
                }
            }
        }
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: playInOrder) {
            Label("Play", systemImage: "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("playlist.play")

        Button(action: playShuffled) {
            Label("Shuffle", systemImage: "shuffle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("playlist.shuffle")
    }
}
