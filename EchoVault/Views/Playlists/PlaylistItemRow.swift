import SwiftUI

struct PlaylistItemRow: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(\.presentPlaylistAddition) private var presentPlaylistAddition

    let item: PlaylistItem
    let track: AudioTrack?
    let folder: MusicFolder?
    let playbackTracks: [AudioTrack]
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            itemContent
                .frame(maxWidth: .infinity)

            PlaylistItemActionsMenu(
                item: item,
                tracks: itemTracks,
                playNext: playNext,
                addToEnd: addToEnd,
                addToPlaylist: addToPlaylist,
                remove: remove
            )
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: remove) {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var itemContent: some View {
        if let track {
            TrackRow(
                track: track,
                isCurrent: player.currentTrack == track,
                isPlaying: player.currentTrack == track && player.isPlaying,
                action: playTrack
            )
        } else if let folder {
            NavigationLink {
                LibraryCollectionDetailView(
                    kind: "Folder",
                    title: folder.title,
                    subtitle: folder.path ?? "On this device",
                    artworkURL: folder.artworkURL,
                    tracks: folder.tracks
                )
            } label: {
                PlaylistFolderRow(folder: folder)
            }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .foregroundStyle(.primary)
                    Text("Unavailable \(item.kind == .folder ? "folder" : "track")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var itemTracks: [AudioTrack] {
        if let track {
            return [track]
        }
        return folder?.tracks ?? []
    }

    private func playTrack() {
        guard let track else {
            return
        }
        if player.currentTrack == track {
            player.togglePlayPause()
        } else {
            player.play(track, in: playbackTracks)
        }
    }

    private func playNext() {
        guard !itemTracks.isEmpty else {
            return
        }
        if item.kind == .folder {
            player.playNext(itemTracks, from: item.title)
        } else if let track {
            player.playNext(track)
        }
    }

    private func addToEnd() {
        guard !itemTracks.isEmpty else {
            return
        }
        if item.kind == .folder {
            player.addToEndOfQueue(itemTracks, from: item.title)
        } else if let track {
            player.addToEndOfQueue(track)
        }
    }

    private func addToPlaylist() {
        let draft = PlaylistItemDraft(
            kind: item.kind,
            referenceID: item.referenceID,
            title: item.title,
            subtitle: item.subtitle
        )
        presentPlaylistAddition([draft], sourceTitle: "“\(item.title)”")
    }
}

private struct PlaylistFolderRow: View {
    let folder: MusicFolder

    var body: some View {
        HStack(spacing: 12) {
            TrackArtworkView(artworkURL: folder.artworkURL, cornerRadius: 8, symbolSize: 17)
                .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(folder.tracks.count) \(folder.tracks.count == 1 ? "track" : "tracks")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

private struct PlaylistItemActionsMenu: View {
    let item: PlaylistItem
    let tracks: [AudioTrack]
    let playNext: () -> Void
    let addToEnd: () -> Void
    let addToPlaylist: () -> Void
    let remove: () -> Void

    var body: some View {
        Menu {
            Button(action: playNext) {
                Label(
                    item.kind == .folder ? "Play Folder Next" : "Play Next",
                    systemImage: "text.insert"
                )
            }
            .disabled(tracks.isEmpty)

            Button(action: addToEnd) {
                Label(
                    item.kind == .folder ? "Add Folder to End of Queue" : "Add to End of Queue",
                    systemImage: "text.badge.plus"
                )
            }
            .disabled(tracks.isEmpty)

            Button(action: addToPlaylist) {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            .disabled(tracks.isEmpty)
            .accessibilityIdentifier("playlist.item.add-to-playlist")

            Divider()
            Button(role: .destructive, action: remove) {
                Label("Remove from Playlist", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions for \(item.title)")
    }
}
