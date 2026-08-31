import SwiftUI

struct PlaylistContentPickerView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(\.dismiss) private var dismiss

    let playlistID: MusicPlaylist.ID
    @State private var searchText = ""
    @State private var alert: UserFacingAlert?

    private var playlist: MusicPlaylist? {
        playlistStore.playlist(id: playlistID)
    }

    var body: some View {
        NavigationStack {
            List {
                if matchingFolders.isEmpty && matchingTracks.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .listRowBackground(Color.clear)
                } else {
                    if !matchingFolders.isEmpty {
                        Section("Folders") {
                            ForEach(matchingFolders) { folder in
                                PlaylistFolderPickerRow(
                                    folder: folder,
                                    isAdded: contains(kind: .folder, referenceID: folder.id),
                                    add: { add(.folder(folder)) }
                                )
                            }
                        }
                    }

                    if !matchingTracks.isEmpty {
                        Section("Individual Tracks") {
                            ForEach(matchingTracks) { track in
                                PlaylistTrackPickerRow(
                                    track: track,
                                    isAdded: contains(kind: .track, referenceID: track.id),
                                    add: { add(.track(track)) }
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .echoVaultBlackSurface()
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search folders or tracks")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .presentationBackground(EchoVaultTheme.background)
        .accessibilityIdentifier("playlist.content.picker")
    }

    private var matchingFolders: [MusicFolder] {
        guard !searchText.isEmpty else {
            return library.folders
        }
        return library.folders.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.path?.localizedCaseInsensitiveContains(searchText) == true
        }
    }

    private var matchingTracks: [AudioTrack] {
        library.tracks.filter {
            searchText.isEmpty
                || $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.artist.localizedCaseInsensitiveContains(searchText)
                || $0.albumDisplayTitle.localizedCaseInsensitiveContains(searchText)
        }
        .sorted {
            let titleComparison = $0.title.localizedStandardCompare($1.title)
            return titleComparison == .orderedSame
                ? $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
                : titleComparison == .orderedAscending
        }
    }

    private func contains(kind: PlaylistItemKind, referenceID: String) -> Bool {
        playlist?.items.contains {
            $0.kind == kind && $0.referenceID == referenceID
        } == true
    }

    private func add(_ draft: PlaylistItemDraft) {
        do {
            _ = try playlistStore.add([draft], to: playlistID)
        } catch {
            alert = UserFacingAlert(
                title: "Could not update playlist",
                message: error.localizedDescription
            )
        }
    }
}

private struct PlaylistFolderPickerRow: View {
    let folder: MusicFolder
    let isAdded: Bool
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(folder.tracks.count) \(folder.tracks.count == 1 ? "track" : "tracks")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isAdded ? .green : Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
        .accessibilityLabel(isAdded ? "\(folder.title) folder already added" : "Add \(folder.title) folder")
    }
}

private struct PlaylistTrackPickerRow: View {
    let track: AudioTrack
    let isAdded: Bool
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: 12) {
                TrackArtworkView(artworkURL: track.artworkURL, cornerRadius: 8, symbolSize: 17)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isAdded ? .green : Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
        .accessibilityLabel(isAdded ? "\(track.title) already added" : "Add \(track.title)")
    }
}
