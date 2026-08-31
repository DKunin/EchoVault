import SwiftUI

struct WebDAVRootView: View {
    @Environment(WebDAVSettings.self) private var settings
    @Environment(MusicLibrary.self) private var library
    @State private var scrollPositions: [WebDAVLocation.ID: WebDAVItem.ID] = [:]

    var body: some View {
        Group {
            if let configuration = settings.configuration {
                WebDAVDirectoryView(
                    configuration: configuration,
                    location: WebDAVLocation(name: "WebDAV", url: configuration.rootURL),
                    scrollPosition: scrollPosition(
                        for: WebDAVLocation(name: "WebDAV", url: configuration.rootURL)
                    )
                )
                .id(settings.revision)
                .navigationDestination(for: WebDAVLocation.self) { location in
                    WebDAVDirectoryView(
                        configuration: configuration,
                        location: location,
                        scrollPosition: scrollPosition(for: location)
                    )
                }
            } else {
                List {
                    Section {
                        ContentUnavailableView {
                            Label(
                                "Connect a WebDAV server",
                                systemImage: "externaldrive.badge.plus"
                            )
                        } description: {
                            Text(
                                "Enter the server address and credentials, verify them, and start browsing in one step."
                            )
                        } actions: {
                            NavigationLink {
                                WebDAVConnectionView(dismissAfterConnection: true)
                            } label: {
                                Label("Connect WebDAV", systemImage: "link")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .listRowBackground(Color.clear)

                    if !library.cachedTracks.isEmpty {
                        Section("Available Offline") {
                            ForEach(library.cachedTracks) { track in
                                CachedWebDAVTrackRow(
                                    track: track,
                                    queue: library.cachedTracks
                                )
                            }
                        }
                        .listRowBackground(EchoVaultTheme.background)
                    }
                }
                .listStyle(.insetGrouped)
                .echoVaultBlackSurface()
                .navigationTitle("WebDAV")
            }
        }
        .onChange(of: settings.revision) {
            scrollPositions.removeAll()
        }
        .accessibilityIdentifier("webdav.view")
    }

    private func scrollPosition(for location: WebDAVLocation) -> Binding<WebDAVItem.ID?> {
        Binding(
            get: { scrollPositions[location.id] },
            set: { newPosition in
                if let newPosition {
                    scrollPositions[location.id] = newPosition
                }
            }
        )
    }
}

private enum DirectoryLoadState {
    case idle
    case loading
    case loaded([WebDAVItem])
    case failed(String)
}

private enum FolderAction: Equatable {
    case makeLocal
    case play
}

private enum RemoteQueuePlacement {
    case next
    case end
}

private struct FolderDownloadToast: Identifiable, Equatable {
    let id = UUID()
    let trackCount: Int

    var message: String {
        "Downloaded \(trackCount) \(trackCount == 1 ? "track" : "tracks")"
    }
}

private struct WebDAVDirectoryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayer.self) private var player
    @Environment(DownloadCenter.self) private var downloads
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.presentPlaylistAddition) private var presentPlaylistAddition

    let configuration: WebDAVConfiguration
    let location: WebDAVLocation
    @Binding var scrollPosition: WebDAVItem.ID?

    @State private var state: DirectoryLoadState = .idle
    @State private var folderAction: FolderAction?
    @State private var folderDownloadToast: FolderDownloadToast?
    @State private var alert: UserFacingAlert?
    @State private var shouldRestoreScrollPosition = true

    var body: some View {
        content
            .navigationTitle(location.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await load()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading || isFolderOperationActive)
                }
            }
            .task(id: location.id) {
                await loadIfNeeded()
            }
            .alert(item: $alert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .overlay(alignment: .top) {
                if let folderDownloadToast {
                    WebDAVFolderDownloadToast(toast: folderDownloadToast)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.snappy, value: folderDownloadToast)
            .task(id: folderDownloadToast?.id) {
                guard let toastID = folderDownloadToast?.id else {
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard folderDownloadToast?.id == toastID else {
                    return
                }
                folderDownloadToast = nil
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            List {
                ForEach(0..<4, id: \.self) { index in
                    HStack(spacing: 12) {
                        Image(systemName: index.isMultiple(of: 2) ? "folder.fill" : "music.note")
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading) {
                            Text("Loading item")
                            Text("WebDAV")
                                .font(.caption)
                        }
                    }
                }
                .redacted(reason: .placeholder)
                .listRowBackground(EchoVaultTheme.background)
            }
            .listStyle(.plain)
            .echoVaultBlackSurface()

        case .failed(let message):
            List {
                Section {
                    ContentUnavailableView {
                        Label("Could not load WebDAV", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") {
                            Task {
                                await load()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .listRowBackground(Color.clear)

                if !cachedTracksInLocation.isEmpty {
                    Section("Available Offline") {
                        ForEach(cachedTracksInLocation) { track in
                            CachedWebDAVTrackRow(
                                track: track,
                                queue: cachedTracksInLocation
                            )
                        }
                    }
                    .listRowBackground(EchoVaultTheme.background)
                }
            }
            .listStyle(.insetGrouped)
            .echoVaultBlackSurface()

        case .loaded(let items):
            if items.isEmpty {
                ContentUnavailableView(
                    "No music in this folder",
                    systemImage: "folder",
                    description: Text("EchoVault shows supported audio files and subfolders.")
                )
            } else {
                ScrollViewReader { proxy in
                    List {
                        Section {
                            directorySummary(items)
                                .id(topScrollTargetID)
                                .listRowInsets(
                                    EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
                                )
                            folderActions
                                .id(actionsScrollTargetID)
                                .listRowInsets(
                                    EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
                                )
                        }
                        .listRowBackground(EchoVaultTheme.background)

                        Section("Contents") {
                            ForEach(items) { item in
                                if item.isDirectory {
                                    NavigationLink(
                                        value: WebDAVLocation(name: item.name, url: item.url)
                                    ) {
                                        WebDAVFolderRow(
                                            item: item,
                                            isDownloaded: library.isFolderDownloaded(at: item.url)
                                        )
                                    }
                                    .id(item.id)
                                } else {
                                    WebDAVTrackRow(
                                        item: item,
                                        cachedTrack: library.cachedTrack(matching: item),
                                        isDownloading: downloads.isDownloading(item),
                                        playAction: {
                                            Task {
                                                await playOrDownload(item)
                                            }
                                        },
                                        downloadAction: {
                                            Task {
                                                await downloadOnly(item)
                                            }
                                        },
                                        playNextAction: {
                                            Task {
                                                await enqueue(item, placement: .next)
                                            }
                                        },
                                        addToEndAction: {
                                            Task {
                                                await enqueue(item, placement: .end)
                                            }
                                        },
                                        addToPlaylistAction: {
                                            Task {
                                                await addToPlaylist(item)
                                            }
                                        },
                                        isFavourite: library.cachedTrack(matching: item).map {
                                            library.isFavourite($0)
                                        } ?? false,
                                        toggleFavouriteAction: {
                                            Task {
                                                await toggleFavourite(item)
                                            }
                                        }
                                    )
                                    .id(item.id)
                                }
                            }
                        }
                        .listRowBackground(EchoVaultTheme.background)
                    }
                    .listStyle(.plain)
                    .scrollPosition(id: trackedScrollPosition, anchor: .top)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .listSectionSpacing(.compact)
                    .echoVaultBlackSurface()
                    .refreshable {
                        await load()
                    }
                    .task {
                        await restoreScrollPosition(using: proxy)
                    }
                    .onDisappear {
                        shouldRestoreScrollPosition = true
                    }
                }
            }
        }
    }

    private var folderActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) {
                        folderActionButtons
                    }
                } else {
                    HStack(spacing: 10) {
                        folderActionButtons
                    }
                }
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .labelStyle(.titleAndIcon)
            .disabled(isFolderOperationActive)

            if let folderStatus = downloads.folderStatus(at: location.url) {
                switch folderStatus {
                case .discovering:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning this folder and its subfolders…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(
                            value: Double(progress.completed),
                            total: Double(max(progress.total, 1))
                        )
                        Text("Downloaded \(progress.completed) of \(progress.total) tracks for offline playback…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var folderActionButtons: some View {
        Button {
            performFolderAction(.play)
        } label: {
            Label("Play", systemImage: "play.fill")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Play Folder")
        .accessibilityIdentifier("webdav.folder.play")

        Button {
            performFolderAction(.makeLocal)
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Download Folder")
        .accessibilityIdentifier("webdav.folder.local")
    }

    private var isLoading: Bool {
        if case .loading = state {
            return true
        }
        return false
    }

    private var cachedTracksInLocation: [AudioTrack] {
        let directoryPath =
            location.url.standardized.path.hasSuffix("/")
            ? location.url.standardized.path
            : "\(location.url.standardized.path)/"
        return library.cachedTracks.filter { track in
            guard let remoteURL = track.remoteURL else {
                return false
            }
            return remoteURL.standardized.path.hasPrefix(directoryPath)
        }
    }

    private var isFolderOperationActive: Bool {
        folderAction != nil || downloads.folderStatus(at: location.url) != nil
    }

    private var topScrollTargetID: WebDAVItem.ID {
        "echovault:webdav:top:\(location.id)"
    }

    private var actionsScrollTargetID: WebDAVItem.ID {
        "echovault:webdav:actions:\(location.id)"
    }

    private var trackedScrollPosition: Binding<WebDAVItem.ID?> {
        Binding(
            get: { scrollPosition },
            set: { newPosition in
                guard !shouldRestoreScrollPosition, let newPosition else {
                    return
                }
                scrollPosition = newPosition
            }
        )
    }

    private func loadIfNeeded() async {
        guard case .idle = state else {
            return
        }
        await load()
    }

    private func restoreScrollPosition(using proxy: ScrollViewProxy) async {
        guard let savedPosition = scrollPosition else {
            shouldRestoreScrollPosition = false
            return
        }
        await Task.yield()
        guard !Task.isCancelled else {
            return
        }
        proxy.scrollTo(savedPosition, anchor: .top)
        await Task.yield()
        guard !Task.isCancelled else {
            return
        }
        shouldRestoreScrollPosition = false
    }

    private func load() async {
        state = .loading
        do {
            let items = try await WebDAVClient(configuration: configuration)
                .listDirectory(at: location.url)
            if Task.isCancelled {
                return
            }
            state = .loaded(items)
        } catch is CancellationError {
            return
        } catch {
            state = .failed(WebDAVConnectionErrorMessage.message(for: error))
        }
    }

    private func playOrDownload(_ item: WebDAVItem) async {
        do {
            let track = try await localTrack(for: item)
            player.play(track, in: library.tracks)
        } catch is CancellationError {
            return
        } catch {
            alert = UserFacingAlert(
                title: "Download failed",
                message: error.localizedDescription
            )
        }
    }

    private func downloadOnly(_ item: WebDAVItem) async {
        do {
            _ = try await localTrack(for: item)
        } catch is CancellationError {
            return
        } catch {
            alert = UserFacingAlert(
                title: "Download failed",
                message: error.localizedDescription
            )
        }
    }

    @ViewBuilder
    private func directorySummary(_ items: [WebDAVItem]) -> some View {
        let folderCount = items.filter(\.isDirectory).count
        let trackItems = items.filter { !$0.isDirectory }
        let offlineCount = trackItems.filter { library.cachedTrack(matching: $0) != nil }.count
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                directorySummaryLabels(
                    folderCount: folderCount,
                    trackCount: trackItems.count,
                    offlineCount: offlineCount
                )
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 12) {
                directorySummaryLabels(
                    folderCount: folderCount,
                    trackCount: trackItems.count,
                    offlineCount: offlineCount
                )
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func directorySummaryLabels(
        folderCount: Int,
        trackCount: Int,
        offlineCount: Int
    ) -> some View {
        Label("\(folderCount) folders", systemImage: "folder")
        Label("\(trackCount) tracks", systemImage: "music.note")
        if !dynamicTypeSize.isAccessibilitySize {
            Spacer(minLength: 4)
        }
        Label("\(offlineCount) offline", systemImage: "arrow.down.circle.fill")
            .foregroundStyle(.secondary)
    }

    private func enqueue(_ item: WebDAVItem, placement: RemoteQueuePlacement) async {
        do {
            let track = try await localTrack(for: item)
            switch placement {
            case .next:
                player.playNext(track)
            case .end:
                player.addToEndOfQueue(track)
            }
        } catch is CancellationError {
            return
        } catch {
            alert = UserFacingAlert(
                title: "Could not add to queue",
                message: error.localizedDescription
            )
        }
    }

    private func toggleFavourite(_ item: WebDAVItem) async {
        do {
            let track = try await localTrack(for: item)
            library.toggleFavourite(track)
        } catch is CancellationError {
            return
        } catch {
            alert = UserFacingAlert(
                title: "Could not update Favourites",
                message: error.localizedDescription
            )
        }
    }

    private func addToPlaylist(_ item: WebDAVItem) async {
        do {
            let track = try await localTrack(for: item)
            presentPlaylistAddition([.track(track)], sourceTitle: "“\(track.title)”")
        } catch is CancellationError {
            return
        } catch {
            alert = UserFacingAlert(
                title: "Could not add to playlist",
                message: error.localizedDescription
            )
        }
    }

    private func localTrack(for item: WebDAVItem) async throws -> AudioTrack {
        if let cachedTrack = library.cachedTrack(matching: item) {
            return cachedTrack
        }
        return try await downloads.cache(item, using: configuration)
    }

    private func performFolderAction(_ action: FolderAction) {
        guard !isFolderOperationActive else {
            return
        }
        folderAction = action
        Task {
            do {
                let tracks = try await downloads.cacheFolder(
                    at: location.url,
                    using: configuration
                ) { _ in }
                folderAction = nil
                switch action {
                case .makeLocal:
                    folderDownloadToast = FolderDownloadToast(trackCount: tracks.count)
                case .play:
                    guard let firstTrack = tracks.first else {
                        throw DownloadCenter.DownloadError.noAudioFiles
                    }
                    player.play(firstTrack, in: tracks)
                }
            } catch is CancellationError {
                folderAction = nil
            } catch {
                folderAction = nil
                alert = UserFacingAlert(
                    title: action == .play ? "Could not play folder" : "Could not make folder local",
                    message: error.localizedDescription
                )
            }
        }
    }
}

private struct WebDAVFolderDownloadToast: View {
    let toast: FolderDownloadToast

    var body: some View {
        Label(toast.message, systemImage: "checkmark.circle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
            .accessibilityIdentifier("webdav.folder.download.toast")
    }
}

private struct WebDAVFolderRow: View {
    let item: WebDAVItem
    let isDownloaded: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(isDownloaded ? "Downloaded" : "Not downloaded")
                    .font(.caption)
                    .foregroundStyle(isDownloaded ? .green : .secondary)
            }

            Spacer(minLength: 8)

            if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WebDAVTrackRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let item: WebDAVItem
    let cachedTrack: AudioTrack?
    let isDownloading: Bool
    let playAction: () -> Void
    let downloadAction: () -> Void
    let playNextAction: () -> Void
    let addToEndAction: () -> Void
    let addToPlaylistAction: () -> Void
    let isFavourite: Bool
    let toggleFavouriteAction: () -> Void

    private var title: String {
        cachedTrack?.title ?? AudioFileSupport.displayTitle(for: item.name)
    }

    private var artist: String {
        cachedTrack?.artist ?? "Unknown Artist"
    }

    private var isCached: Bool {
        cachedTrack != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: playAction) {
                HStack(spacing: 12) {
                    TrackArtworkView(
                        artworkURL: cachedTrack?.artworkURL,
                        cornerRadius: 8,
                        symbolSize: 17
                    )
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        HStack(spacing: 5) {
                            Text(artist)
                            if isCached {
                                Label("Offline", systemImage: "checkmark.circle.fill")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(
                isCached
                    ? "Play \(title) by \(artist)"
                    : "Download and play \(title)"
            )

            if isDownloading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Downloading \(title)")
            } else if isCached {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Available offline")
            } else {
                Button(action: downloadAction) {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Download \(title) for offline playback")
            }

            TrackQueueActionsMenu(
                trackTitle: title,
                isFavourite: isFavourite,
                playNext: playNextAction,
                addToEnd: addToEndAction,
                addToPlaylist: addToPlaylistAction,
                toggleFavourite: toggleFavouriteAction
            )
        }
        .disabled(isDownloading)
        .queueActionsContextMenu(
            isFavourite: isFavourite,
            playNext: playNextAction,
            addToEnd: addToEndAction,
            addToPlaylist: addToPlaylistAction,
            toggleFavourite: toggleFavouriteAction
        )
    }
}

private struct CachedWebDAVTrackRow: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayer.self) private var player
    @Environment(\.presentPlaylistAddition) private var presentPlaylistAddition

    let track: AudioTrack
    let queue: [AudioTrack]

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
                    player.play(track, in: queue)
                }
            }
            .frame(maxWidth: .infinity)

            TrackQueueActionsMenu(
                trackTitle: track.title,
                isFavourite: library.isFavourite(track),
                playNext: { player.playNext(track) },
                addToEnd: { player.addToEndOfQueue(track) },
                addToPlaylist: addToPlaylist,
                toggleFavourite: { library.toggleFavourite(track) }
            )
        }
        .queueActionsContextMenu(
            isFavourite: library.isFavourite(track),
            playNext: { player.playNext(track) },
            addToEnd: { player.addToEndOfQueue(track) },
            addToPlaylist: addToPlaylist,
            toggleFavourite: { library.toggleFavourite(track) }
        )
    }

    private func addToPlaylist() {
        presentPlaylistAddition([.track(track)], sourceTitle: "“\(track.title)”")
    }
}

#Preview("WebDAV not configured") {
    NavigationStack {
        WebDAVRootView()
    }
    .environment(WebDAVSettings())
    .environment(MusicLibrary())
    .environment(AudioPlayer())
    .environment(DownloadCenter(library: MusicLibrary()))
}
