import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

struct CachedTrackRecord: Codable, Hashable, Sendable {
    let remoteURL: URL
    let localFilename: String
    let displayFilename: String
    let downloadedAt: Date
    let eTag: String?
    let contentLength: Int64?

    init(
        remoteURL: URL,
        localFilename: String,
        displayFilename: String,
        downloadedAt: Date,
        eTag: String?,
        contentLength: Int64?
    ) {
        self.remoteURL = remoteURL
        self.localFilename = localFilename
        self.displayFilename = displayFilename
        self.downloadedAt = downloadedAt
        self.eTag = eTag
        self.contentLength = contentLength
    }

    private enum CodingKeys: String, CodingKey {
        case remoteURL
        case localFilename
        case displayFilename
        case originalFilename
        case filename
        case downloadedAt
        case eTag
        case contentLength
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteURL = try container.decode(URL.self, forKey: .remoteURL)
        localFilename = try container.decode(String.self, forKey: .localFilename)
        displayFilename =
            try container.decodeIfPresent(String.self, forKey: .displayFilename)
            ?? container.decodeIfPresent(String.self, forKey: .originalFilename)
            ?? container.decodeIfPresent(String.self, forKey: .filename)
            ?? localFilename
        downloadedAt = try container.decode(Date.self, forKey: .downloadedAt)
        eTag = try container.decodeIfPresent(String.self, forKey: .eTag)
        contentLength = try container.decodeIfPresent(Int64.self, forKey: .contentLength)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(remoteURL, forKey: .remoteURL)
        try container.encode(localFilename, forKey: .localFilename)
        try container.encode(displayFilename, forKey: .displayFilename)
        try container.encode(downloadedAt, forKey: .downloadedAt)
        try container.encodeIfPresent(eTag, forKey: .eTag)
        try container.encodeIfPresent(contentLength, forKey: .contentLength)
    }
}

struct DownloadedWebDAVFile: Sendable {
    let temporaryURL: URL
    let item: WebDAVItem
}

struct MusicLibrarySnapshot: Sendable {
    let tracks: [AudioTrack]
    let cachedRecords: [CachedTrackRecord]
    let cacheSizeBytes: Int64
    let librarySizeBytes: Int64
}

struct LocalMusicImportResult: Sendable {
    let snapshot: MusicLibrarySnapshot
    let skippedCount: Int
    let duplicateCount: Int
}

private struct TrackMetadataIndexEntry: Codable, Hashable, Sendable {
    let fileSize: Int64
    let contentModificationDate: Date?
    let title: String
    let artist: String
    let albumTitle: String?
    let artworkFilename: String?
    let artworkProcessingVersion: Int?
}

actor LocalMusicStore {
    private static let artworkProcessingVersion = 1
    private static let maximumArtworkPixelSize = 1_024

    enum StoreError: LocalizedError {
        case unsupportedFile(String)
        case invalidImportFolder
        case noSupportedAudioFiles(String)
        case invalidManagedFile
        case corruptCacheManifest

        var errorDescription: String? {
            switch self {
            case .unsupportedFile(let filename):
                return "\(filename) is not a supported audio file."
            case .invalidImportFolder:
                return "The selected item is not a readable folder."
            case .noSupportedAudioFiles(let folderName):
                return "No supported audio files were found in \(folderName)."
            case .invalidManagedFile:
                return "The requested file is outside EchoVault's managed storage."
            case .corruptCacheManifest:
                return "The offline music index is damaged. Remove and reinstall the app to reset it."
            }
        }
    }

    private let rootURL: URL
    private let importedDirectoryURL: URL
    private let cacheDirectoryURL: URL
    private let artworkDirectoryURL: URL
    private let cacheManifestURL: URL
    private let metadataIndexURL: URL
    private let metadataReader: any AudioMetadataReading
    private let fileManager = FileManager.default
    private let logger = Logger(
        subsystem: "com.example.EchoVault",
        category: "LocalMusicStore"
    )

    init(
        rootURL: URL? = nil,
        metadataReader: any AudioMetadataReading = AVAudioMetadataReader()
    ) {
        let resolvedRoot =
            rootURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("EchoVault", isDirectory: true)
        self.rootURL = resolvedRoot
        importedDirectoryURL = resolvedRoot.appendingPathComponent(
            "ImportedTracks",
            isDirectory: true
        )
        cacheDirectoryURL = resolvedRoot.appendingPathComponent(
            "OfflineTracks",
            isDirectory: true
        )
        artworkDirectoryURL = resolvedRoot.appendingPathComponent(
            "Artwork",
            isDirectory: true
        )
        cacheManifestURL = resolvedRoot.appendingPathComponent("offline-index.json")
        metadataIndexURL = resolvedRoot.appendingPathComponent("metadata-index.json")
        self.metadataReader = metadataReader
    }

    func loadLibrary() async throws -> MusicLibrarySnapshot {
        try prepareStorage()
        return try await makeSnapshot()
    }

    func importFiles(_ urls: [URL]) async throws -> LocalMusicImportResult {
        try prepareStorage()
        guard !urls.isEmpty else {
            return LocalMusicImportResult(
                snapshot: try await makeSnapshot(),
                skippedCount: 0,
                duplicateCount: 0
            )
        }

        for url in urls where !AudioFileSupport.isSupported(url) {
            throw StoreError.unsupportedFile(url.lastPathComponent)
        }

        var copiedURLs: [URL] = []
        var seenSourceURLs = Set<URL>()
        var duplicateCount = 0
        do {
            for sourceURL in urls {
                try Task.checkCancellation()
                guard seenSourceURLs.insert(sourceURL.standardizedFileURL).inserted else {
                    duplicateCount += 1
                    continue
                }
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                let values = try sourceURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw StoreError.unsupportedFile(sourceURL.lastPathComponent)
                }

                let destinationURL = uniqueDestination(
                    named: sourceURL.lastPathComponent,
                    in: importedDirectoryURL,
                    isDirectory: false
                )
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                copiedURLs.append(destinationURL)
            }
        } catch {
            for copiedURL in copiedURLs {
                try? fileManager.removeItem(at: copiedURL)
            }
            throw error
        }

        return LocalMusicImportResult(
            snapshot: try await makeSnapshot(),
            skippedCount: 0,
            duplicateCount: duplicateCount
        )
    }

    func importFolder(_ sourceURL: URL) async throws -> LocalMusicImportResult {
        try prepareStorage()
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceValues = try sourceURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw StoreError.invalidImportFolder
        }

        let regularFiles = try regularFiles(in: sourceURL)
        let sourceFiles = regularFiles.filter(AudioFileSupport.isSupported)
        guard !sourceFiles.isEmpty else {
            throw StoreError.noSupportedAudioFiles(sourceURL.lastPathComponent)
        }

        let destinationRoot = uniqueDestination(
            named: sourceURL.lastPathComponent,
            in: importedDirectoryURL,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: false
        )

        do {
            for sourceFileURL in sourceFiles {
                try Task.checkCancellation()
                let relativeComponents = try relativePathComponents(
                    for: sourceFileURL,
                    within: sourceURL
                )
                guard !relativeComponents.isEmpty else {
                    throw StoreError.invalidImportFolder
                }

                let destinationURL = relativeComponents.reduce(destinationRoot) {
                    $0.appendingPathComponent($1)
                }
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: sourceFileURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: destinationRoot)
            throw error
        }

        return LocalMusicImportResult(
            snapshot: try await makeSnapshot(),
            skippedCount: regularFiles.count - sourceFiles.count,
            duplicateCount: 0
        )
    }

    func cacheDownloadedFile(
        at temporaryURL: URL,
        for item: WebDAVItem
    ) async throws -> MusicLibrarySnapshot {
        try await cacheDownloadedFiles([
            DownloadedWebDAVFile(temporaryURL: temporaryURL, item: item)
        ])
    }

    func cacheDownloadedFiles(
        _ downloads: [DownloadedWebDAVFile]
    ) async throws -> MusicLibrarySnapshot {
        try prepareStorage()
        guard !downloads.isEmpty else {
            return try await makeSnapshot()
        }

        var records = try loadCacheManifest()
        do {
            for download in downloads {
                try Task.checkCancellation()
                try cacheDownloadedFileContents(
                    at: download.temporaryURL,
                    for: download.item,
                    records: &records
                )
            }
        } catch {
            records.sort { $0.remoteURL.absoluteString < $1.remoteURL.absoluteString }
            try? saveCacheManifest(records)
            throw error
        }
        records.sort { $0.remoteURL.absoluteString < $1.remoteURL.absoluteString }
        try saveCacheManifest(records)
        return try await makeSnapshot()
    }

    private func cacheDownloadedFileContents(
        at temporaryURL: URL,
        for item: WebDAVItem,
        records: inout [CachedTrackRecord]
    ) throws {
        guard !item.isDirectory, AudioFileSupport.isSupported(item.url) else {
            throw StoreError.unsupportedFile(item.name)
        }

        let localFilename = cacheFilename(for: item)
        let destinationURL = cacheDirectoryURL.appendingPathComponent(localFilename)
        let stagingURL = cacheDirectoryURL.appendingPathComponent(
            ".\(UUID().uuidString).partial"
        )
        defer {
            try? fileManager.removeItem(at: stagingURL)
        }

        try fileManager.copyItem(at: temporaryURL, to: stagingURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: stagingURL, to: destinationURL)

        if let oldRecord = records.first(where: { $0.remoteURL == item.url }),
            oldRecord.localFilename != localFilename
        {
            let oldURL = cacheDirectoryURL.appendingPathComponent(oldRecord.localFilename)
            if isDirectChild(oldURL, of: cacheDirectoryURL) {
                try? fileManager.removeItem(at: oldURL)
            }
        }
        records.removeAll { $0.remoteURL == item.url || $0.localFilename == localFilename }
        records.append(
            CachedTrackRecord(
                remoteURL: item.url,
                localFilename: localFilename,
                displayFilename: item.name,
                downloadedAt: Date(),
                eTag: item.eTag,
                contentLength: item.contentLength
            )
        )
    }

    func remove(_ track: AudioTrack) async throws -> MusicLibrarySnapshot {
        try prepareStorage()
        let localURL = track.localURL.standardizedFileURL

        switch track.origin {
        case .imported:
            guard isDescendant(localURL, of: importedDirectoryURL) else {
                throw StoreError.invalidManagedFile
            }
            try fileManager.removeItem(at: localURL)
            removeEmptyImportedDirectories(startingAt: localURL.deletingLastPathComponent())

        case .webDAV:
            guard isDirectChild(localURL, of: cacheDirectoryURL) else {
                throw StoreError.invalidManagedFile
            }
            try fileManager.removeItem(at: localURL)
            var records = try loadCacheManifest()
            records.removeAll { $0.localFilename == localURL.lastPathComponent }
            try saveCacheManifest(records)
        }

        return try await makeSnapshot()
    }

    func removeImportedTracks(_ tracks: [AudioTrack]) async throws -> MusicLibrarySnapshot {
        try prepareStorage()
        let localURLs = tracks.map { $0.localURL.standardizedFileURL }
        guard tracks.allSatisfy({ $0.origin == .imported }),
            localURLs.allSatisfy({ isDescendant($0, of: importedDirectoryURL) })
        else {
            throw StoreError.invalidManagedFile
        }

        for localURL in localURLs where fileManager.fileExists(atPath: localURL.path) {
            try fileManager.removeItem(at: localURL)
            removeEmptyImportedDirectories(startingAt: localURL.deletingLastPathComponent())
        }
        return try await makeSnapshot()
    }

    private func makeSnapshot() async throws -> MusicLibrarySnapshot {
        var records = try loadCacheManifest()
        let existingRecords = records.filter { record in
            let url = cacheDirectoryURL.appendingPathComponent(record.localFilename)
            return isDirectChild(url, of: cacheDirectoryURL)
                && fileManager.fileExists(atPath: url.path)
        }
        if existingRecords != records {
            records = existingRecords
            try saveCacheManifest(records)
        }

        let importedURLs = try audioFiles(in: importedDirectoryURL)
        var metadataIndex = loadMetadataIndex()
        let originalMetadataIndex = metadataIndex
        var activeMetadataKeys = Set<String>()
        var tracks: [AudioTrack] = []

        for localURL in importedURLs {
            try Task.checkCancellation()
            let relativeComponents = try relativePathComponents(
                for: localURL,
                within: importedDirectoryURL
            )
            let metadataKey = "imported/\(relativeComponents.joined(separator: "/"))"
            activeMetadataKeys.insert(metadataKey)
            let folderName = relativeComponents.dropLast().last
            let folderIdentifier = relativeComponents.dropLast().joined(separator: "/")
            let track = try await makeTrack(
                localURL: localURL,
                displayFilename: localURL.lastPathComponent,
                folderName: folderName,
                folderIdentifier: folderIdentifier.trimmedNonempty,
                origin: .imported,
                remoteURL: nil,
                downloadedAt: nil,
                metadataKey: metadataKey,
                metadataIndex: &metadataIndex
            )
            tracks.append(track)
        }

        for record in records {
            try Task.checkCancellation()
            let localURL = cacheDirectoryURL.appendingPathComponent(record.localFilename)
            let metadataKey = "cache/\(record.localFilename)"
            activeMetadataKeys.insert(metadataKey)
            let folderName = record.remoteURL.deletingLastPathComponent().lastPathComponent
                .removingPercentEncoding
            let track = try await makeTrack(
                localURL: localURL,
                displayFilename: record.displayFilename,
                folderName: folderName?.trimmedNonempty,
                folderIdentifier: record.remoteURL.deletingLastPathComponent().absoluteString,
                origin: .webDAV,
                remoteURL: record.remoteURL,
                downloadedAt: record.downloadedAt,
                metadataKey: metadataKey,
                metadataIndex: &metadataIndex
            )
            tracks.append(track)
        }

        metadataIndex = metadataIndex.filter { activeMetadataKeys.contains($0.key) }
        if metadataIndex != originalMetadataIndex {
            try saveMetadataIndex(metadataIndex)
        }
        try removeUnusedArtwork(referencedBy: metadataIndex)

        tracks.sort {
            let albumComparison = $0.albumDisplayTitle.localizedStandardCompare(
                $1.albumDisplayTitle
            )
            if albumComparison != .orderedSame {
                return albumComparison == .orderedAscending
            }
            let artistComparison = $0.artist.localizedStandardCompare($1.artist)
            if artistComparison != .orderedSame {
                return artistComparison == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }

        let importedSize = importedURLs.reduce(into: Int64(0)) { result, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            result += Int64(values?.fileSize ?? 0)
        }
        let cacheSize = records.reduce(into: Int64(0)) { result, record in
            let url = cacheDirectoryURL.appendingPathComponent(record.localFilename)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            result += Int64(values?.fileSize ?? 0)
        }
        return MusicLibrarySnapshot(
            tracks: tracks,
            cachedRecords: records,
            cacheSizeBytes: cacheSize,
            librarySizeBytes: importedSize + cacheSize
        )
    }

    private func makeTrack(
        localURL: URL,
        displayFilename: String,
        folderName: String?,
        folderIdentifier: String?,
        origin: TrackOrigin,
        remoteURL: URL?,
        downloadedAt: Date?,
        metadataKey: String,
        metadataIndex: inout [String: TrackMetadataIndexEntry]
    ) async throws -> AudioTrack {
        let values = try localURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let fileSize = Int64(values.fileSize ?? 0)
        let modificationDate = values.contentModificationDate

        let metadata: TrackMetadataIndexEntry
        if let existing = metadataIndex[metadataKey],
            existing.fileSize == fileSize,
            existing.contentModificationDate == modificationDate,
            existing.artworkProcessingVersion == Self.artworkProcessingVersion,
            artworkExists(for: existing.artworkFilename)
        {
            metadata = existing
        } else {
            let extracted: ExtractedAudioMetadata
            do {
                extracted = try await metadataReader.readMetadata(from: localURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.notice(
                    "Metadata unavailable for \(localURL.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)"
                )
                extracted = .empty
            }

            let artworkFilename = try storeArtwork(extracted.artworkData)
            metadata = TrackMetadataIndexEntry(
                fileSize: fileSize,
                contentModificationDate: modificationDate,
                title: extracted.title?.trimmedNonempty
                    ?? AudioFileSupport.displayTitle(for: displayFilename),
                artist: extracted.artist?.trimmedNonempty ?? "Unknown Artist",
                albumTitle: extracted.albumTitle?.trimmedNonempty,
                artworkFilename: artworkFilename,
                artworkProcessingVersion: Self.artworkProcessingVersion
            )
            metadataIndex[metadataKey] = metadata
        }

        let artworkURL = metadata.artworkFilename.map {
            artworkDirectoryURL.appendingPathComponent($0)
        }
        return AudioTrack(
            title: metadata.title,
            artist: metadata.artist,
            albumTitle: metadata.albumTitle,
            folderName: folderName,
            folderIdentifier: folderIdentifier,
            filename: displayFilename,
            localURL: localURL,
            artworkURL: artworkURL,
            origin: origin,
            remoteURL: remoteURL,
            downloadedAt: downloadedAt
        )
    }

    private func supportedAudioFiles(in directoryURL: URL) throws -> [URL] {
        try regularFiles(in: directoryURL).filter(AudioFileSupport.isSupported)
    }

    private func regularFiles(in directoryURL: URL) throws -> [URL] {
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var enumerationError: Error?
        guard
            let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            )
        else {
            throw StoreError.invalidImportFolder
        }

        var result: [URL] = []
        for case let candidateURL as URL in enumerator {
            if let enumerationError {
                throw enumerationError
            }
            let values = try candidateURL.resourceValues(forKeys: Set(resourceKeys))
            guard values.isRegularFile == true,
                values.isSymbolicLink != true
            else {
                continue
            }
            result.append(candidateURL)
        }
        if let enumerationError {
            throw enumerationError
        }
        return result.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func audioFiles(in directoryURL: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }
        return try supportedAudioFiles(in: directoryURL)
    }

    private func relativePathComponents(for url: URL, within directoryURL: URL) throws
        -> [String]
    {
        let baseComponents = directoryURL.standardizedFileURL.pathComponents
        let candidateComponents = url.standardizedFileURL.pathComponents
        guard candidateComponents.count > baseComponents.count,
            Array(candidateComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw StoreError.invalidManagedFile
        }
        let relativeComponents = Array(candidateComponents.dropFirst(baseComponents.count))
        guard relativeComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw StoreError.invalidManagedFile
        }
        return relativeComponents
    }

    private func prepareStorage() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: importedDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: artworkDirectoryURL, withIntermediateDirectories: true)
        try excludeFromBackup(cacheDirectoryURL)
        try excludeFromBackup(artworkDirectoryURL)
    }

    private func excludeFromBackup(_ directoryURL: URL) throws {
        var mutableURL = directoryURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private func loadCacheManifest() throws -> [CachedTrackRecord] {
        guard fileManager.fileExists(atPath: cacheManifestURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: cacheManifestURL)
            let records = try JSONDecoder().decode([CachedTrackRecord].self, from: data)
            guard Set(records.map(\.remoteURL)).count == records.count,
                Set(records.map(\.localFilename)).count == records.count,
                records.allSatisfy({ record in
                    let url = cacheDirectoryURL.appendingPathComponent(record.localFilename)
                    return !record.localFilename.isEmpty
                        && record.localFilename == URL(fileURLWithPath: record.localFilename).lastPathComponent
                        && isDirectChild(url, of: cacheDirectoryURL)
                })
            else {
                throw StoreError.corruptCacheManifest
            }
            return records
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.corruptCacheManifest
        }
    }

    private func saveCacheManifest(_ records: [CachedTrackRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: cacheManifestURL, options: .atomic)
    }

    private func loadMetadataIndex() -> [String: TrackMetadataIndexEntry] {
        guard fileManager.fileExists(atPath: metadataIndexURL.path) else {
            return [:]
        }
        do {
            let data = try Data(contentsOf: metadataIndexURL)
            return try JSONDecoder().decode(
                [String: TrackMetadataIndexEntry].self,
                from: data
            )
        } catch {
            logger.error(
                "Metadata index will be rebuilt: \(error.localizedDescription, privacy: .private)"
            )
            return [:]
        }
    }

    private func saveMetadataIndex(_ index: [String: TrackMetadataIndexEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: metadataIndexURL, options: .atomic)
    }

    private func storeArtwork(_ data: Data?) throws -> String? {
        guard let data, !data.isEmpty else {
            return nil
        }
        let storedData = optimizedArtworkData(data) ?? data
        let digest = SHA256.hash(data: storedData)
            .map { String(format: "%02x", $0) }
            .joined()
        let filename = "\(digest).artwork"
        let destinationURL = artworkDirectoryURL.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: destinationURL.path) {
            try storedData.write(to: destinationURL, options: .atomic)
        }
        return filename
    }

    private func optimizedArtworkData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumArtworkPixelSize,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            )
        else {
            return nil
        }

        let destinationData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                destinationData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.86
        ]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return destinationData as Data
    }

    private func artworkExists(for filename: String?) -> Bool {
        guard let filename else {
            return true
        }
        let url = artworkDirectoryURL.appendingPathComponent(filename)
        return filename == URL(fileURLWithPath: filename).lastPathComponent
            && isDirectChild(url, of: artworkDirectoryURL)
            && fileManager.fileExists(atPath: url.path)
    }

    private func removeUnusedArtwork(
        referencedBy metadataIndex: [String: TrackMetadataIndexEntry]
    ) throws {
        let referencedFilenames = Set(metadataIndex.values.compactMap(\.artworkFilename))
        let contents = try fileManager.contentsOfDirectory(
            at: artworkDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for url in contents where !referencedFilenames.contains(url.lastPathComponent) {
            guard isDirectChild(url, of: artworkDirectoryURL) else {
                continue
            }
            try fileManager.removeItem(at: url)
        }
    }

    private func cacheFilename(for item: WebDAVItem) -> String {
        let digest = SHA256.hash(data: Data(item.url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let fileExtension = item.url.pathExtension.lowercased()
        return fileExtension.isEmpty ? digest : "\(digest).\(fileExtension)"
    }

    private func uniqueDestination(
        named proposedName: String,
        in directoryURL: URL,
        isDirectory: Bool
    ) -> URL {
        let safeName =
            URL(fileURLWithPath: proposedName).lastPathComponent.trimmedNonempty
            ?? (isDirectory ? "Imported Folder" : "Imported Audio")
        let proposedURL = directoryURL.appendingPathComponent(
            safeName,
            isDirectory: isDirectory
        )
        guard fileManager.fileExists(atPath: proposedURL.path) else {
            return proposedURL
        }

        let originalURL = URL(fileURLWithPath: safeName)
        let fileExtension = isDirectory ? "" : originalURL.pathExtension
        let baseName =
            isDirectory || fileExtension.isEmpty
            ? safeName
            : originalURL.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let candidateName =
                fileExtension.isEmpty
                ? "\(baseName) \(suffix)"
                : "\(baseName) \(suffix).\(fileExtension)"
            let candidateURL = directoryURL.appendingPathComponent(
                candidateName,
                isDirectory: isDirectory
            )
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            suffix += 1
        }
    }

    private func isDirectChild(_ url: URL, of directoryURL: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        return standardizedURL.deletingLastPathComponent() == directoryURL.standardizedFileURL
    }

    private func isDescendant(_ url: URL, of directoryURL: URL) -> Bool {
        let baseComponents = directoryURL.standardizedFileURL.pathComponents
        let candidateComponents = url.standardizedFileURL.pathComponents
        return candidateComponents.count > baseComponents.count
            && Array(candidateComponents.prefix(baseComponents.count)) == baseComponents
    }

    private func removeEmptyImportedDirectories(startingAt directoryURL: URL) {
        var currentURL = directoryURL
        while currentURL != importedDirectoryURL, isDescendant(currentURL, of: importedDirectoryURL) {
            guard
                let contents = try? fileManager.contentsOfDirectory(atPath: currentURL.path),
                contents.isEmpty
            else {
                return
            }
            try? fileManager.removeItem(at: currentURL)
            currentURL.deleteLastPathComponent()
        }
    }
}

private extension String {
    var trimmedNonempty: String? {
        let result = trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
