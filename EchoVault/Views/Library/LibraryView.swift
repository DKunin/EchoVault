import SwiftUI
import UniformTypeIdentifiers

enum LibraryImportKind: Equatable {
    case files
    case folder

    var allowedContentTypes: [UTType] {
        switch self {
        case .files:
            return [.audio]
        case .folder:
            return [.folder]
        }
    }

    var allowsMultipleSelection: Bool {
        self == .files
    }
}

private enum LibraryViewMode: String, CaseIterable, Identifiable {
    case folders
    case tracks
    case favourites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracks: "Tracks"
        case .folders: "Folders"
        case .favourites: "Favourites"
        }
    }

    var systemImage: String {
        switch self {
        case .tracks: "music.note"
        case .folders: "folder"
        case .favourites: "heart"
        }
    }
}

private enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case title
    case artist

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private enum LibraryPresentation {
    case tracks([AudioTrack])
    case folders([MusicFolder])
    case favourites([AudioTrack])

    var isEmpty: Bool {
        switch self {
        case .tracks(let tracks):
            tracks.isEmpty
        case .folders(let folders):
            folders.isEmpty
        case .favourites(let tracks):
            tracks.isEmpty
        }
    }
}

struct LibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var searchText = ""
    @State private var importKind: LibraryImportKind = .files
    @State private var isPresentingImporter = false
    @State private var selectedMode: LibraryViewMode = .folders
    @State private var sortOrder: LibrarySortOrder = .title
    @State private var expandedCollectionIDs: Set<String> = []
    @State private var importResult: MusicImportResult?
    @State private var isUndoingImport = false
    @State private var alert: UserFacingAlert?

    var body: some View {
        let presentation = libraryPresentation

        VStack(spacing: 0) {
            modePicker
                .frame(minHeight: 44)
                .padding(.horizontal, EchoVaultTheme.horizontalContentPadding)
                .padding(.vertical, 8)
                .background(EchoVaultTheme.background)

            List {
                if let importResult {
                    Section {
                        ImportSummaryView(
                            result: importResult,
                            isUndoing: isUndoingImport,
                            undo: undoLastImport,
                            viewTracks: viewImportedTracks,
                            dismiss: { self.importResult = nil }
                        )
                    }
                    .listRowBackground(EchoVaultTheme.background)
                }

                if let errorMessage = library.errorMessage, !library.tracks.isEmpty {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    .listRowBackground(EchoVaultTheme.background)
                }
                if library.isLoading && library.tracks.isEmpty {
                    loadingRows
                } else if let errorMessage = library.errorMessage, library.tracks.isEmpty {
                    errorState(message: errorMessage)
                } else if presentation.isEmpty {
                    emptyState
                } else {
                    libraryContent(presentation)
                }
            }
            .listStyle(.plain)
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 1)
            .echoVaultBlackSurface()
            .accessibilityIdentifier("library.view")
            .refreshable {
                await library.refresh()
            }
        }
        .background(EchoVaultTheme.background)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search title, artist, or album"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort library", selection: $sortOrder) {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("library.sort")
            }
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if library.isImporting || isUndoingImport {
                    ProgressView()
                        .accessibilityLabel("Importing music")
                } else {
                    Menu {
                        Button {
                            presentImporter(.files)
                        } label: {
                            Label("Import files", systemImage: "music.note")
                        }
                        .accessibilityIdentifier("library.import.files")
                        Button {
                            presentImporter(.folder)
                        } label: {
                            Label("Import folder", systemImage: "folder")
                        }
                        .accessibilityIdentifier("library.import.folder")
                    } label: {
                        Label("Import music", systemImage: "plus")
                    }
                    .accessibilityIdentifier("library.import")
                }
            }
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            allowedContentTypes: importKind.allowedContentTypes,
            allowsMultipleSelection: importKind.allowsMultipleSelection
        ) { result in
            handleImport(result, kind: importKind)
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var modePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Library view", selection: $selectedMode) {
                libraryModeOptions
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("library.mode")
        } else {
            Picker("Library view", selection: $selectedMode) {
                libraryModeOptions
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("library.mode")
        }
    }

    @ViewBuilder
    private var libraryModeOptions: some View {
        ForEach(LibraryViewMode.allCases) { mode in
            Text(mode.title).tag(mode)
        }
    }

    @ViewBuilder
    private func libraryContent(_ presentation: LibraryPresentation) -> some View {
        switch presentation {
        case .tracks(let tracks):
            Section("All Tracks") {
                trackRows(tracks)
            }
        case .folders(let folders):
            folderSections(folders)
        case .favourites(let tracks):
            Section("Favourites") {
                trackRows(tracks)
            }
        }
    }

    @ViewBuilder
    private func folderSections(_ folders: [MusicFolder]) -> some View {
        ForEach(folders) { folder in
            DisclosureGroup(
                isExpanded: expansionBinding(for: "folder:\(folder.id)")
            ) {
                NavigationLink {
                    LibraryCollectionDetailView(
                        kind: "Folder",
                        title: folder.title,
                        subtitle: folder.path ?? "On this device",
                        artworkURL: folder.artworkURL,
                        tracks: folder.tracks
                    )
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }

                ForEach(folder.tracks) { track in
                    LibraryTrackRow(
                        track: track,
                        playTrack: {
                            player.play(track, in: folder.tracks)
                        },
                        reportError: { alert = $0 }
                    )
                    .listRowBackground(EchoVaultTheme.background)
                }
            } label: {
                HStack(spacing: 0) {
                    FolderSectionHeader(folder: folder)
                    FolderQueueActionsMenu(
                        folder: folder,
                        folderTitle: folder.title,
                        playNext: {
                            player.playNext(folder.tracks, from: folder.title)
                        },
                        addToEnd: {
                            player.addToEndOfQueue(folder.tracks, from: folder.title)
                        }
                    )
                }
            }
            .accessibilityHint("Double-tap to expand or collapse this folder")
            .listRowBackground(EchoVaultTheme.background)
            .libraryRowStyle()
        }
    }

    @ViewBuilder
    private func trackRows(_ tracks: [AudioTrack]) -> some View {
        ForEach(tracks) { track in
            LibraryTrackRow(
                track: track,
                playTrack: {
                    player.play(track, in: tracks)
                },
                reportError: { alert = $0 }
            )
            .listRowBackground(EchoVaultTheme.background)
            .libraryRowStyle()
        }
    }

    private var filteredFolders: [MusicFolder] {
        library.folders.compactMap { folder in
            let matchesFolder =
                searchText.isEmpty
                || folder.title.localizedCaseInsensitiveContains(searchText)
                || folder.path?.localizedCaseInsensitiveContains(searchText) == true
            let tracks = matchesFolder ? folder.tracks : folder.tracks.filter(matchesSearch)
            guard !tracks.isEmpty else {
                return nil
            }
            return MusicFolder(groupingKey: folder.id, tracks: tracks)
        }
        .sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var sortedMatchingTracks: [AudioTrack] {
        library.tracks.filter(matchesSearch).sorted { lhs, rhs in
            switch sortOrder {
            case .title:
                let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
                return titleComparison == .orderedSame
                    ? lhs.artist.localizedStandardCompare(rhs.artist) == .orderedAscending
                    : titleComparison == .orderedAscending
            case .artist:
                let artistComparison = lhs.artist.localizedStandardCompare(rhs.artist)
                return artistComparison == .orderedSame
                    ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    : artistComparison == .orderedAscending
            }
        }
    }

    private var sortedFavouriteTracks: [AudioTrack] {
        library.favouriteTracks.filter(matchesSearch).sorted { lhs, rhs in
            switch sortOrder {
            case .title:
                let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
                return titleComparison == .orderedSame
                    ? lhs.artist.localizedStandardCompare(rhs.artist) == .orderedAscending
                    : titleComparison == .orderedAscending
            case .artist:
                let artistComparison = lhs.artist.localizedStandardCompare(rhs.artist)
                return artistComparison == .orderedSame
                    ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                    : artistComparison == .orderedAscending
            }
        }
    }

    private var libraryPresentation: LibraryPresentation {
        switch selectedMode {
        case .tracks:
            .tracks(sortedMatchingTracks)
        case .folders:
            .folders(filteredFolders)
        case .favourites:
            .favourites(sortedFavouriteTracks)
        }
    }

    private func matchesSearch(_ track: AudioTrack) -> Bool {
        searchText.isEmpty
            || track.title.localizedCaseInsensitiveContains(searchText)
            || track.artist.localizedCaseInsensitiveContains(searchText)
            || track.albumDisplayTitle.localizedCaseInsensitiveContains(searchText)
            || track.folderName?.localizedCaseInsensitiveContains(searchText) == true
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedCollectionIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedCollectionIDs.insert(id)
                } else {
                    expandedCollectionIDs.remove(id)
                }
            }
        )
    }

    private var loadingRows: some View {
        Section {
            ForEach(0..<4, id: \.self) { index in
                TrackRow(
                    track: AudioTrack(
                        title: "Loading track \(index + 1)",
                        filename: "Loading.m4a",
                        localURL: URL(fileURLWithPath: "/placeholder/\(index).m4a"),
                        origin: .imported
                    ),
                    isCurrent: false,
                    isPlaying: false,
                    action: {}
                )
            }
            .redacted(reason: .placeholder)
        }
        .listRowBackground(EchoVaultTheme.background)
    }

    private var emptyState: some View {
        let isEmptyFavourites = selectedMode == .favourites && searchText.isEmpty
        return ContentUnavailableView {
            if isEmptyFavourites {
                Label("No favourites yet", systemImage: "heart")
            } else if searchText.isEmpty {
                VStack(spacing: 14) {
                    AppLogoView(cornerRadius: 24)
                        .frame(width: 112, height: 112)
                    Text("No music yet")
                        .font(.title3.bold())
                }
            } else {
                Label("No matching tracks", systemImage: "magnifyingglass")
            }
        } description: {
            if isEmptyFavourites {
                Text("Add tracks from Library, WebDAV, or Now Playing.")
            } else if searchText.isEmpty {
                Text("Import audio files or a folder, or download tracks from WebDAV.")
            } else {
                Text("Try a different title, artist, or album.")
            }
        } actions: {
            if searchText.isEmpty && !isEmptyFavourites {
                HStack {
                    Button {
                        presentImporter(.files)
                    } label: {
                        Label("Import files", systemImage: "music.note")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        presentImporter(.folder)
                    } label: {
                        Label("Import folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .listRowBackground(Color.clear)
    }

    private func errorState(message: String) -> some View {
        ContentUnavailableView {
            Label("Library unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") {
                Task {
                    await library.refresh()
                }
            }
            .buttonStyle(.bordered)
        }
        .listRowBackground(Color.clear)
    }

    private func presentImporter(_ kind: LibraryImportKind) {
        importKind = kind
        isPresentingImporter = true
    }

    private func handleImport(
        _ result: Result<[URL], any Error>,
        kind: LibraryImportKind
    ) {
        switch kind {
        case .files:
            handleFileImport(result)
        case .folder:
            handleFolderImport(result)
        }
    }

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            Task {
                do {
                    importResult = try await library.importFiles(urls)
                } catch {
                    showImportError(error)
                }
            }
        case .failure(let error):
            showImportError(error)
        }
    }

    private func handleFolderImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let folderURL = urls.first else {
                return
            }
            Task {
                do {
                    importResult = try await library.importFolder(folderURL)
                } catch {
                    showImportError(error)
                }
            }
        case .failure(let error):
            showImportError(error)
        }
    }

    private func showImportError(_ error: any Error) {
        alert = UserFacingAlert(
            title: "Import failed",
            message: error.localizedDescription
        )
    }

    private func undoLastImport() {
        guard let importResult, !isUndoingImport else {
            return
        }
        isUndoingImport = true
        Task {
            defer { isUndoingImport = false }
            do {
                try await library.undoImport(importResult)
                self.importResult = nil
            } catch {
                alert = UserFacingAlert(
                    title: "Could not undo import",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func viewImportedTracks() {
        searchText = ""
        selectedMode = .tracks
        importResult = nil
    }
}

private struct ImportSummaryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let result: MusicImportResult
    let isUndoing: Bool
    let undo: () -> Void
    let viewTracks: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Label("Import complete", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer(minLength: 8)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss import summary")
            }

            Text(
                "\(result.importedCount) imported · \(result.skippedCount) skipped · \(result.duplicateCount) duplicates"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        actionButtons
                    }
                } else {
                    HStack(spacing: 10) {
                        actionButtons
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("library.import.summary")
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            undo()
        } label: {
            if isUndoing {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Label("Undo Import", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .disabled(isUndoing || result.importedTracks.isEmpty)

        Button {
            viewTracks()
        } label: {
            Label("View Tracks", systemImage: "music.note.list")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(result.importedTracks.isEmpty)
    }
}

private struct LibraryTrackRow: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayer.self) private var player
    @Environment(\.presentPlaylistAddition) private var presentPlaylistAddition

    let track: AudioTrack
    let playTrack: () -> Void
    let reportError: (UserFacingAlert) -> Void
    @State private var isConfirmingDeletion = false
    @State private var isDeleting = false

    var body: some View {
        HStack(spacing: 0) {
            TrackRow(
                track: track,
                isCurrent: player.currentTrack == track,
                isPlaying: player.currentTrack == track && player.isPlaying
            ) {
                if player.currentTrack == track {
                    player.togglePlayPause()
                } else {
                    playTrack()
                }
            }
            .frame(maxWidth: .infinity)

            TrackQueueActionsMenu(
                trackTitle: track.title,
                isFavourite: library.isFavourite(track),
                playNext: { player.playNext(track) },
                addToEnd: { player.addToEndOfQueue(track) },
                addToPlaylist: addToPlaylist,
                toggleFavourite: { library.toggleFavourite(track) },
                deleteFromDevice: { isConfirmingDeletion = true }
            )
        }
        .disabled(isDeleting)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                isConfirmingDeletion = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .queueActionsContextMenu(
            isFavourite: library.isFavourite(track),
            playNext: { player.playNext(track) },
            addToEnd: { player.addToEndOfQueue(track) },
            addToPlaylist: addToPlaylist,
            toggleFavourite: { library.toggleFavourite(track) },
            deleteFromDevice: { isConfirmingDeletion = true }
        )
        .confirmationDialog(
            "Delete “\(track.title)” from this device?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete from Device", role: .destructive, action: deleteTrack)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deletionMessage)
        }
    }

    private var deletionMessage: String {
        switch track.origin {
        case .imported:
            "This removes EchoVault’s managed copy. The original file outside EchoVault is not changed."
        case .webDAV:
            "This removes the offline download. You can download it again from WebDAV."
        }
    }

    private func addToPlaylist() {
        presentPlaylistAddition([.track(track)], sourceTitle: "“\(track.title)”")
    }

    private func deleteTrack() {
        guard !isDeleting else {
            return
        }
        isDeleting = true
        let wasCurrentTrack = player.currentTrack == track
        if wasCurrentTrack {
            player.stop()
        }
        Task {
            defer { isDeleting = false }
            do {
                try await library.remove(track)
                player.removeTrackFromPlayback(track)
            } catch {
                reportError(
                    UserFacingAlert(
                        title: "Could not delete track",
                        message: error.localizedDescription
                    )
                )
            }
        }
    }
}

private struct FolderSectionHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let folder: MusicFolder

    var body: some View {
        HStack(spacing: 12) {
            TrackArtworkView(
                artworkURL: folder.artworkURL,
                cornerRadius: 10,
                symbolSize: 20
            )
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(
                    "\(folder.tracks.count) \(folder.tracks.count == 1 ? "track" : "tracks")\(folder.path.map { " · \($0)" } ?? "")"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct FolderQueueActionsMenu: View {
    @Environment(\.presentPlaylistAddition) private var presentPlaylistAddition

    let folder: MusicFolder
    let folderTitle: String
    let playNext: () -> Void
    let addToEnd: () -> Void

    var body: some View {
        Menu {
            Button(action: playNext) {
                Label("Play Folder Next", systemImage: "text.insert")
            }
            .accessibilityIdentifier("folder.queue.next")

            Button(action: addToEnd) {
                Label("Add Folder to End of Queue", systemImage: "text.badge.plus")
            }
            .accessibilityIdentifier("folder.queue.append")

            Button(action: addToPlaylist) {
                Label("Add Folder to Playlist", systemImage: "music.note.list")
            }
            .accessibilityIdentifier("folder.playlist.add")
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Queue actions for \(folderTitle) folder")
    }

    private func addToPlaylist() {
        presentPlaylistAddition([.folder(folder)], sourceTitle: "“\(folder.title)”")
    }
}

struct LibraryCollectionDetailView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayer.self) private var player
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var alert: UserFacingAlert?
    @State private var visibleTrackCount = 0

    let kind: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let tracks: [AudioTrack]
    private static let initialTrackBatchSize = 120
    private static let trackBatchSize = 120

    var body: some View {
        let tracksForPlayback = availableTracks
        let tracksToRender = tracksForPlayback.prefix(visibleTrackCount)
        List {
            Section {
                VStack(spacing: 14) {
                    TrackArtworkView(
                        artworkURL: artworkURL,
                        cornerRadius: 24,
                        symbolSize: 54,
                        maxPixelSize: 512
                    )
                    .frame(width: 180, height: 180)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)

                    VStack(spacing: 4) {
                        Text(title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text(
                            "\(tracksForPlayback.count) \(tracksForPlayback.count == 1 ? "track" : "tracks")"
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            Section {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 10) {
                            playbackButtons(tracksForPlayback)
                        }
                    } else {
                        HStack(spacing: 12) {
                            playbackButtons(tracksForPlayback)
                        }
                    }
                }
                .disabled(availableTracks.isEmpty)
            }
            .listRowBackground(EchoVaultTheme.background)

            Section("Tracks") {
                ForEach(tracksToRender) { track in
                    LibraryTrackRow(
                        track: track,
                        playTrack: {
                            player.play(track, in: tracksForPlayback)
                        },
                        reportError: { alert = $0 }
                    )
                    .listRowBackground(EchoVaultTheme.background)
                }

                if visibleTrackCount < tracksForPlayback.count {
                    Button {
                        loadMoreTracks(availableCount: tracksForPlayback.count)
                    } label: {
                        Text("Load more")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .listRowBackground(EchoVaultTheme.background)
                    .accessibilityIdentifier("library.\(kind.lowercased()).detail.loadMore")
                }
            }
        }
        .listStyle(.insetGrouped)
        .echoVaultBlackSurface()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            visibleTrackCount = min(Self.initialTrackBatchSize, tracksForPlayback.count)
        }
        .onChange(of: library.revision) { _, _ in
            visibleTrackCount = min(Self.initialTrackBatchSize, availableTracks.count)
        }
        .accessibilityIdentifier("library.\(kind.lowercased()).detail")
    }

    @ViewBuilder
    private func playbackButtons(_ availableTracks: [AudioTrack]) -> some View {
        Button {
            player.playInOrder(availableTracks)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Play")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        Button {
            player.playShuffled(availableTracks)
        } label: {
            Label("Shuffle", systemImage: "shuffle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var availableTracks: [AudioTrack] {
        guard !tracks.isEmpty else {
            return []
        }
        if tracks.count == library.trackIDs.count
            && tracks.allSatisfy({ library.trackIDs.contains($0.id) })
        {
            return tracks
        }
        return tracks.filter { track in
            library.trackIDs.contains(track.id)
        }
    }

    private func loadMoreTracks(availableCount: Int) {
        let nextLimit = visibleTrackCount + Self.trackBatchSize
        visibleTrackCount = min(nextLimit, availableCount)
    }
}

private extension View {
    func libraryRowStyle() -> some View {
        listRowInsets(
            EdgeInsets(
                top: 8,
                leading: EchoVaultTheme.horizontalContentPadding,
                bottom: 8,
                trailing: 12
            )
        )
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(EchoVaultTheme.separator)
    }
}

#if DEBUG
    #Preview("Empty library") {
        NavigationStack {
            LibraryView()
        }
        .environment(MusicLibrary())
        .environment(AudioPlayer())
    }

    #Preview("Loaded library") {
        NavigationStack {
            LibraryView()
        }
        .environment(MusicLibrary.preview(tracks: [.previewImported, .previewCached]))
        .environment(AudioPlayer.preview(track: .previewCached))
    }
#endif
