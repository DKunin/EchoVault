import SwiftUI

struct PlaylistsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(PlaylistStore.self) private var playlistStore

    @State private var creationRequest: PlaylistCreationRequest?
    @State private var playlistPendingDeletion: MusicPlaylist?
    @State private var isImportingPlaylist = false
    @State private var alert: UserFacingAlert?

    var body: some View {
        List {
            if let errorMessage = playlistStore.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                .listRowBackground(EchoVaultTheme.background)
            }

            if playlistStore.playlists.isEmpty {
                PlaylistsEmptyState(create: presentCreatePlaylist)
                    .listRowBackground(Color.clear)
            } else {
                Section("Your Playlists") {
                    ForEach(playlistStore.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlistID: playlist.id)
                        } label: {
                            PlaylistRow(playlist: playlist)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                playlistPendingDeletion = playlist
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                playlistPendingDeletion = playlist
                            } label: {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                        }
                    }
                }
                .listRowBackground(EchoVaultTheme.background)
            }
        }
        .listStyle(.insetGrouped)
        .echoVaultBlackSurface()
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Import Playlist", systemImage: "square.and.arrow.down") {
                    isImportingPlaylist = true
                }
                .accessibilityIdentifier("playlist.import")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: presentCreatePlaylist) {
                    Label("New Playlist", systemImage: "plus")
                }
                .accessibilityIdentifier("playlist.create")
            }
        }
        .fileImporter(
            isPresented: $isImportingPlaylist,
            allowedContentTypes: [.echoVaultPlaylist],
            allowsMultipleSelection: false,
            onCompletion: importPlaylist
        )
        .sheet(item: $creationRequest) { request in
            CreatePlaylistView(request: request, onCreated: {})
        }
        .confirmationDialog(
            "Delete \(playlistPendingDeletion?.name ?? "playlist")?",
            isPresented: deletionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive, action: deletePlaylist)
            Button("Cancel", role: .cancel) {
                playlistPendingDeletion = nil
            }
        } message: {
            Text("This removes the playlist only. Music files stay on this device.")
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .accessibilityIdentifier("playlists.view")
    }

    private var deletionConfirmation: Binding<Bool> {
        Binding(
            get: { playlistPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    playlistPendingDeletion = nil
                }
            }
        )
    }

    private func presentCreatePlaylist() {
        creationRequest = PlaylistCreationRequest()
    }

    private func deletePlaylist() {
        guard let playlist = playlistPendingDeletion else {
            return
        }
        defer { playlistPendingDeletion = nil }
        do {
            try playlistStore.deletePlaylist(id: playlist.id)
        } catch {
            alert = UserFacingAlert(
                title: "Could not delete playlist",
                message: error.localizedDescription
            )
        }
    }

    private func importPlaylist(_ result: Result<[URL], any Error>) {
        do {
            let url = try result.get().first
            guard let url else {
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let fileSize, fileSize > PlaylistDocument.maximumFileSize {
                throw PlaylistDocumentError.fileTooLarge
            }
            let document = try PlaylistDocument(data: Data(contentsOf: url, options: .mappedIfSafe))
            let playlistID = try playlistStore.importPlaylist(document.playlist)
            guard let importedPlaylist = playlistStore.playlist(id: playlistID) else {
                throw PlaylistStoreError.playlistNotFound
            }
            let unavailableCount = importedPlaylist.unavailableItemCount(
                availableTracks: library.tracks,
                availableFolders: library.folders
            )
            let message =
                unavailableCount == 0
                ? "“\(importedPlaylist.name)” is ready to play."
                : "“\(importedPlaylist.name)” was imported. \(unavailableCount) item(s) will become available after the matching WebDAV music is downloaded."
            alert = UserFacingAlert(title: "Playlist imported", message: message)
        } catch {
            alert = UserFacingAlert(
                title: "Could not import playlist",
                message: error.localizedDescription
            )
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayer.self) private var player
    @Environment(PlaylistStore.self) private var playlistStore

    let playlistID: MusicPlaylist.ID
    @State private var isAddingMusic = false
    @State private var isExportingPlaylist = false
    @State private var exportDocument: PlaylistDocument?
    @State private var exportFilename = "Playlist"
    @State private var alert: UserFacingAlert?

    private var playlist: MusicPlaylist? {
        playlistStore.playlist(id: playlistID)
    }

    private var resolvedTracks: [AudioTrack] {
        playlist?.resolvedTracks(
            availableTracks: library.tracks,
            availableFolders: library.folders
        ) ?? []
    }

    var body: some View {
        Group {
            if let playlist {
                PlaylistDetailList(
                    playlist: playlist,
                    resolvedTracks: resolvedTracks,
                    playInOrder: playInOrder,
                    playShuffled: playShuffled,
                    removeItem: removeItem,
                    removeItems: removeItems,
                    moveItems: moveItems
                )
            } else {
                ContentUnavailableView(
                    "Playlist unavailable",
                    systemImage: "music.note.list",
                    description: Text("This playlist may have been deleted.")
                )
            }
        }
        .background(EchoVaultTheme.background)
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if playlist != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export Playlist", systemImage: "square.and.arrow.up") {
                        exportPlaylist()
                    }
                    .accessibilityIdentifier("playlist.export")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: presentMusicPicker) {
                        Label("Add Music", systemImage: "plus")
                    }
                    .accessibilityIdentifier("playlist.detail.add")
                }
            }
        }
        .fileExporter(
            isPresented: $isExportingPlaylist,
            document: exportDocument,
            contentType: .echoVaultPlaylist,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result {
                alert = UserFacingAlert(
                    title: "Could not export playlist",
                    message: error.localizedDescription
                )
            }
        }
        .sheet(isPresented: $isAddingMusic) {
            PlaylistContentPickerView(playlistID: playlistID)
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .accessibilityIdentifier("playlist.detail")
    }

    private func presentMusicPicker() {
        isAddingMusic = true
    }

    private func exportPlaylist() {
        guard let playlist else {
            return
        }
        exportDocument = PlaylistDocument(
            playlist: playlist,
            availableTracks: library.tracks,
            availableFolders: library.folders
        )
        exportFilename = PlaylistDocument.defaultFilename(for: playlist)
        isExportingPlaylist = true
    }

    private func playInOrder() {
        player.playInOrder(resolvedTracks)
    }

    private func playShuffled() {
        player.playShuffled(resolvedTracks)
    }

    private func removeItem(_ itemID: PlaylistItem.ID) {
        performMutation {
            try playlistStore.removeItem(id: itemID, from: playlistID)
        }
    }

    private func removeItems(_ offsets: IndexSet) {
        performMutation {
            try playlistStore.removeItems(at: offsets, from: playlistID)
        }
    }

    private func moveItems(_ source: IndexSet, _ destination: Int) {
        performMutation {
            try playlistStore.moveItems(from: source, to: destination, in: playlistID)
        }
    }

    private func performMutation(_ mutation: () throws -> Void) {
        do {
            try mutation()
        } catch {
            alert = UserFacingAlert(
                title: "Could not update playlist",
                message: error.localizedDescription
            )
        }
    }
}

private struct PlaylistRow: View {
    let playlist: MusicPlaylist

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(playlist.items.count) \(playlist.items.count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PlaylistsEmptyState: View {
    let create: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No playlists yet", systemImage: "music.note.list")
        } description: {
            Text("Create a playlist, then add folders or individual tracks.")
        } actions: {
            Button(action: create) {
                Label("New Playlist", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#if DEBUG
    #Preview("Playlists") {
        NavigationStack {
            PlaylistsView()
        }
        .environment(PlaylistStore())
        .environment(MusicLibrary.preview(tracks: [.previewImported, .previewCached]))
        .environment(AudioPlayer())
    }
#endif
