import Foundation
import Observation

struct MusicImportResult: Identifiable, Equatable, Sendable {
    let id = UUID()
    let importedTracks: [AudioTrack]
    let skippedCount: Int
    let duplicateCount: Int

    var importedCount: Int {
        importedTracks.count
    }
}

@MainActor
@Observable
final class MusicLibrary {
    private(set) var tracks: [AudioTrack] = []
    private(set) var albums: [MusicAlbum] = []
    private(set) var folders: [MusicFolder] = []
    private(set) var importedTracks: [AudioTrack] = []
    private(set) var cachedTracks: [AudioTrack] = []
    private(set) var trackIDs: Set<String> = []
    private(set) var favouriteTrackIDs: Set<AudioTrack.ID>
    private(set) var revision = 0
    private(set) var isLoading = false
    private(set) var isImporting = false
    private(set) var errorMessage: String?
    private(set) var cacheSizeBytes: Int64 = 0
    private(set) var librarySizeBytes: Int64 = 0
    private(set) var cachedFolderKeys: Set<String> = []

    @ObservationIgnored private let store: LocalMusicStore
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let favouritesKey: String
    @ObservationIgnored private var cachedRecordsByRemoteURL: [URL: CachedTrackRecord] = [:]
    @ObservationIgnored private var cachedTracksByRemoteURL: [URL: AudioTrack] = [:]

    init(
        store: LocalMusicStore = LocalMusicStore(),
        userDefaults: UserDefaults = .standard,
        favouritesKey: String = "musicLibrary.favouriteTrackIDs"
    ) {
        self.store = store
        self.userDefaults = userDefaults
        self.favouritesKey = favouritesKey
        favouriteTrackIDs = Set(userDefaults.stringArray(forKey: favouritesKey) ?? [])
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            apply(try await store.loadLibrary())
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFiles(_ urls: [URL]) async throws -> MusicImportResult {
        isImporting = true
        defer { isImporting = false }
        do {
            let existingTrackIDs = Set(tracks.map(\.id))
            let result = try await store.importFiles(urls)
            apply(result.snapshot)
            errorMessage = nil
            return importResult(from: result, excluding: existingTrackIDs)
        } catch {
            await refresh()
            throw error
        }
    }

    func importFolder(_ url: URL) async throws -> MusicImportResult {
        isImporting = true
        defer { isImporting = false }
        do {
            let existingTrackIDs = Set(tracks.map(\.id))
            let result = try await store.importFolder(url)
            apply(result.snapshot)
            errorMessage = nil
            return importResult(from: result, excluding: existingTrackIDs)
        } catch {
            await refresh()
            throw error
        }
    }

    func undoImport(_ result: MusicImportResult) async throws {
        let importedIDs = Set(result.importedTracks.map(\.id))
        let currentImportedTracks = tracks.filter {
            $0.origin == .imported && importedIDs.contains($0.id)
        }
        apply(try await store.removeImportedTracks(currentImportedTracks))
        errorMessage = nil
    }

    func addDownloadedFile(at temporaryURL: URL, item: WebDAVItem) async throws -> AudioTrack {
        let tracks = try await addDownloadedFiles([
            DownloadedWebDAVFile(temporaryURL: temporaryURL, item: item)
        ])
        guard let track = tracks.first else {
            throw WebDAVClient.ClientError.invalidResponse
        }
        return track
    }

    func addDownloadedFiles(_ downloads: [DownloadedWebDAVFile]) async throws -> [AudioTrack] {
        apply(try await store.cacheDownloadedFiles(downloads))
        errorMessage = nil
        let remoteURLs = Set(downloads.map(\.item.url))
        let downloadedTracks = tracks.filter { track in
            track.remoteURL.map(remoteURLs.contains) == true
        }
        guard downloadedTracks.count == remoteURLs.count else {
            throw WebDAVClient.ClientError.invalidResponse
        }
        return downloadedTracks
    }

    func remove(_ track: AudioTrack) async throws {
        apply(try await store.remove(track))
        errorMessage = nil
    }

    func cachedTrack(matching item: WebDAVItem) -> AudioTrack? {
        guard let record = cachedRecordsByRemoteURL[item.url] else {
            return nil
        }
        if let remoteETag = item.eTag,
            let cachedETag = record.eTag,
            remoteETag != cachedETag
        {
            return nil
        }
        if let remoteLength = item.contentLength,
            let cachedLength = record.contentLength,
            remoteLength != cachedLength
        {
            return nil
        }
        return cachedTracksByRemoteURL[item.url]
    }

    func isFolderDownloaded(at directoryURL: URL) -> Bool {
        guard let key = Self.canonicalDirectoryKey(directoryURL) else {
            return false
        }
        return cachedFolderKeys.contains(key)
    }

    var favouriteTracks: [AudioTrack] {
        tracks.filter { favouriteTrackIDs.contains($0.id) }
    }

    func isFavourite(_ track: AudioTrack) -> Bool {
        trackIDs.contains(track.id) && favouriteTrackIDs.contains(track.id)
    }

    func toggleFavourite(_ track: AudioTrack) {
        guard trackIDs.contains(track.id) else {
            return
        }
        if favouriteTrackIDs.contains(track.id) {
            favouriteTrackIDs.remove(track.id)
        } else {
            favouriteTrackIDs.insert(track.id)
        }
        saveFavourites()
    }

    func addToFavourites(_ track: AudioTrack) {
        guard trackIDs.contains(track.id), favouriteTrackIDs.insert(track.id).inserted else {
            return
        }
        saveFavourites()
    }

    func albums(containing tracks: [AudioTrack]) -> [MusicAlbum] {
        Dictionary(grouping: tracks, by: \.albumGroupingKey)
            .map { MusicAlbum(groupingKey: $0.key, tracks: $0.value) }
            .sorted {
                let titleComparison = $0.title.localizedStandardCompare($1.title)
                if titleComparison != .orderedSame {
                    return titleComparison == .orderedAscending
                }
                return $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
            }
    }

    func folders(containing tracks: [AudioTrack]) -> [MusicFolder] {
        Dictionary(grouping: tracks) { track in
            track.folderIdentifier ?? track.folderName ?? "unfiled"
        }
        .map { MusicFolder(groupingKey: $0.key, tracks: $0.value) }
        .sorted {
            let titleComparison = $0.title.localizedStandardCompare($1.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }
            return ($0.path ?? "").localizedStandardCompare($1.path ?? "")
                == .orderedAscending
        }
    }

    private func apply(_ snapshot: MusicLibrarySnapshot) {
        tracks = snapshot.tracks
        trackIDs = Set(tracks.map(\.id))
        if !favouriteTrackIDs.isSubset(of: trackIDs) {
            favouriteTrackIDs.formIntersection(trackIDs)
            saveFavourites()
        }
        albums = albums(containing: snapshot.tracks)
        folders = folders(containing: snapshot.tracks)

        var imported: [AudioTrack] = []
        var cached: [AudioTrack] = []
        var tracksByRemoteURL: [URL: AudioTrack] = [:]
        for track in tracks {
            switch track.origin {
            case .imported:
                imported.append(track)
            case .webDAV:
                cached.append(track)
                if let remoteURL = track.remoteURL {
                    tracksByRemoteURL[remoteURL] = track
                }
            }
        }
        importedTracks = imported
        cachedTracks = cached
        cachedTracksByRemoteURL = tracksByRemoteURL
        cachedFolderKeys = Set(
            cached.compactMap(\.remoteURL).flatMap(Self.ancestorDirectoryKeys)
        )

        var recordsByRemoteURL: [URL: CachedTrackRecord] = [:]
        for record in snapshot.cachedRecords {
            recordsByRemoteURL[record.remoteURL] = record
        }
        cachedRecordsByRemoteURL = recordsByRemoteURL
        cacheSizeBytes = snapshot.cacheSizeBytes
        librarySizeBytes = snapshot.librarySizeBytes
        revision &+= 1
    }

    private func saveFavourites() {
        userDefaults.set(favouriteTrackIDs.sorted(), forKey: favouritesKey)
    }

    private static func canonicalDirectoryKey(_ url: URL) -> String? {
        var components = URLComponents(url: url.standardized, resolvingAgainstBaseURL: false)
        guard let scheme = components?.scheme?.lowercased(),
            let host = components?.host?.lowercased()
        else {
            return nil
        }
        components?.scheme = scheme
        components?.host = host
        components?.user = nil
        components?.password = nil
        components?.query = nil
        components?.fragment = nil
        if (scheme == "https" && components?.port == 443)
            || (scheme == "http" && components?.port == 80)
        {
            components?.port = nil
        }
        if var path = components?.percentEncodedPath {
            if path.isEmpty {
                path = "/"
            }
            if !path.hasSuffix("/") {
                path.append("/")
            }
            components?.percentEncodedPath = path
        }
        return components?.string
    }

    private static func ancestorDirectoryKeys(for remoteURL: URL) -> [String] {
        var keys: [String] = []
        var directoryURL = remoteURL.deletingLastPathComponent()
        while true {
            if let key = canonicalDirectoryKey(directoryURL) {
                keys.append(key)
            }
            let parentURL = directoryURL.deletingLastPathComponent()
            if parentURL.standardized.path == directoryURL.standardized.path {
                break
            }
            directoryURL = parentURL
        }
        return keys
    }

    private func importResult(
        from result: LocalMusicImportResult,
        excluding existingTrackIDs: Set<AudioTrack.ID>
    ) -> MusicImportResult {
        MusicImportResult(
            importedTracks: tracks.filter {
                $0.origin == .imported && !existingTrackIDs.contains($0.id)
            },
            skippedCount: result.skippedCount,
            duplicateCount: result.duplicateCount
        )
    }
}

#if DEBUG
    extension MusicLibrary {
        static func preview(tracks: [AudioTrack] = []) -> MusicLibrary {
            let library = MusicLibrary()
            library.tracks = tracks
            library.trackIDs = Set(tracks.map(\.id))
            library.albums = library.albums(containing: tracks)
            library.folders = library.folders(containing: tracks)
            library.importedTracks = tracks.filter { $0.origin == .imported }
            library.cachedTracks = tracks.filter { $0.origin == .webDAV }
            library.cachedFolderKeys = Set(
                library.cachedTracks.compactMap(\.remoteURL).flatMap(Self.ancestorDirectoryKeys)
            )
            return library
        }
    }
#endif
