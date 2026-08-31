import XCTest

@testable import EchoVault

private actor CountingMetadataReader: AudioMetadataReading {
    private(set) var callCount = 0

    func readMetadata(from _: URL) async throws -> ExtractedAudioMetadata {
        callCount += 1
        return ExtractedAudioMetadata(
            title: "Indexed Title",
            artist: "Indexed Artist",
            albumTitle: "Indexed Album",
            artworkData: nil
        )
    }
}

final class LocalMusicStoreTests: XCTestCase {
    func testCachesReloadsAndRemovesDownloadedTrack() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoVaultTests-\(UUID().uuidString)", isDirectory: true)
        let store = LocalMusicStore(rootURL: rootURL)
        let remoteURL = try XCTUnwrap(
            URL(string: "https://dav.example.com/music/test-tone.m4a")
        )
        let item = WebDAVItem(
            name: "test-tone.m4a",
            url: remoteURL,
            isDirectory: false,
            contentLength: 9_000,
            lastModified: nil,
            eTag: "\"fixture\""
        )

        let cachedSnapshot = try await store.cacheDownloadedFile(at: fixtureURL, for: item)
        let cachedTrack = try XCTUnwrap(cachedSnapshot.tracks.first)
        XCTAssertEqual(cachedTrack.origin, .webDAV)
        XCTAssertEqual(cachedTrack.remoteURL, remoteURL)
        XCTAssertEqual(cachedTrack.title, "test-tone")
        XCTAssertEqual(cachedTrack.artist, "Unknown Artist")
        XCTAssertEqual(cachedTrack.albumDisplayTitle, "music")
        XCTAssertGreaterThan(cachedSnapshot.cacheSizeBytes, 0)
        XCTAssertEqual(cachedSnapshot.librarySizeBytes, cachedSnapshot.cacheSizeBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedTrack.localURL.path))

        let reloadedSnapshot = try await store.loadLibrary()
        XCTAssertEqual(reloadedSnapshot.tracks, [cachedTrack])

        let emptySnapshot = try await store.remove(cachedTrack)
        XCTAssertTrue(emptySnapshot.tracks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedTrack.localURL.path))
    }

    func testLibrarySizeIncludesImportedAndDownloadedAudio() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let fixtureSize = Int64(
            try XCTUnwrap(fixtureURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoVaultLibrarySizeTests-\(UUID().uuidString)", isDirectory: true)
        let store = LocalMusicStore(rootURL: rootURL)

        let importedSnapshot = try await store.importFiles([fixtureURL]).snapshot

        XCTAssertEqual(importedSnapshot.cacheSizeBytes, 0)
        XCTAssertEqual(importedSnapshot.librarySizeBytes, fixtureSize)

        let remoteURL = try XCTUnwrap(
            URL(string: "https://dav.example.com/music/Downloaded.m4a")
        )
        let downloadedSnapshot = try await store.cacheDownloadedFile(
            at: fixtureURL,
            for: WebDAVItem(
                name: "Downloaded.m4a",
                url: remoteURL,
                isDirectory: false,
                contentLength: fixtureSize,
                lastModified: nil,
                eTag: nil
            )
        )

        XCTAssertEqual(downloadedSnapshot.cacheSizeBytes, fixtureSize)
        XCTAssertEqual(downloadedSnapshot.librarySizeBytes, fixtureSize * 2)
    }

    func testImportsFolderRecursivelyAndUsesEmbeddedMetadata() async throws {
        let taggedFixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "tagged-tone", withExtension: "m4a")
        )
        let untaggedFixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoVaultFolderTests-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = temporaryRoot.appendingPathComponent("Imported Album", isDirectory: true)
        let discOne = sourceFolder.appendingPathComponent("Disc 1", isDirectory: true)
        let discTwo = sourceFolder.appendingPathComponent("Disc 2", isDirectory: true)
        try FileManager.default.createDirectory(at: discOne, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: discTwo, withIntermediateDirectories: true)
        let taggedDestination = discOne.appendingPathComponent("opaque-source-name.m4a")
        let untaggedDestination = discTwo.appendingPathComponent("Plain Tone.m4a")
        let skippedDestination = sourceFolder.appendingPathComponent("notes.txt")
        try FileManager.default.copyItem(at: taggedFixtureURL, to: taggedDestination)
        try FileManager.default.copyItem(at: untaggedFixtureURL, to: untaggedDestination)
        try Data("not audio".utf8).write(to: skippedDestination)

        let storeRoot = temporaryRoot.appendingPathComponent("Store", isDirectory: true)
        let store = LocalMusicStore(rootURL: storeRoot)
        let importResult = try await store.importFolder(sourceFolder)
        let snapshot = importResult.snapshot

        XCTAssertEqual(snapshot.tracks.count, 2)
        XCTAssertEqual(importResult.skippedCount, 1)
        let taggedTrack = try XCTUnwrap(snapshot.tracks.first { $0.title == "Tagged Tone" })
        XCTAssertEqual(taggedTrack.artist, "Echo Artist")
        XCTAssertEqual(taggedTrack.albumTitle, "Echo Album")
        XCTAssertEqual(taggedTrack.folderName, "Disc 1")
        XCTAssertTrue(try XCTUnwrap(taggedTrack.artworkURL).isFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: taggedTrack.artworkURL?.path ?? ""))
        XCTAssertTrue(
            taggedTrack.localURL.path.hasSuffix(
                "ImportedTracks/Imported Album/Disc 1/opaque-source-name.m4a"
            )
        )

        let plainTrack = try XCTUnwrap(snapshot.tracks.first { $0.title == "Plain Tone" })
        XCTAssertEqual(plainTrack.artist, "Unknown Artist")
        XCTAssertEqual(plainTrack.albumDisplayTitle, "Disc 2")

        let reloadedSnapshot = try await store.loadLibrary()
        XCTAssertEqual(reloadedSnapshot.tracks, snapshot.tracks)
    }

    func testCachesDownloadedFilesAsOneBatch() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EchoVaultBatchCacheTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = LocalMusicStore(rootURL: rootURL)
        let firstURL = try XCTUnwrap(
            URL(string: "https://dav.example.com/music/Album/First.m4a")
        )
        let secondURL = try XCTUnwrap(
            URL(string: "https://dav.example.com/music/Album/Second.m4a")
        )
        let downloads = [firstURL, secondURL].map { remoteURL in
            DownloadedWebDAVFile(
                temporaryURL: fixtureURL,
                item: WebDAVItem(
                    name: remoteURL.lastPathComponent,
                    url: remoteURL,
                    isDirectory: false,
                    contentLength: nil,
                    lastModified: nil,
                    eTag: nil
                )
            )
        }

        let snapshot = try await store.cacheDownloadedFiles(downloads)

        XCTAssertEqual(snapshot.tracks.count, 2)
        XCTAssertEqual(Set(snapshot.tracks.compactMap(\.remoteURL)), Set([firstURL, secondURL]))
        XCTAssertTrue(snapshot.tracks.allSatisfy { $0.albumDisplayTitle == "Album" })
        XCTAssertTrue(
            snapshot.tracks.allSatisfy {
                FileManager.default.fileExists(atPath: $0.localURL.path)
            }
        )
    }

    @MainActor
    func testMusicLibraryIndexesCachedTracksAndValidatesRemoteMetadata() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EchoVaultIndexedCacheTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = LocalMusicStore(rootURL: rootURL)
        let remoteURL = try XCTUnwrap(
            URL(string: "https://dav.example.com/music/Indexed.m4a")
        )
        let item = WebDAVItem(
            name: "Indexed.m4a",
            url: remoteURL,
            isDirectory: false,
            contentLength: 9_000,
            lastModified: nil,
            eTag: "\"indexed\""
        )
        _ = try await store.cacheDownloadedFile(at: fixtureURL, for: item)
        let library = MusicLibrary(store: store)

        await library.refresh()

        let cachedTrack = try XCTUnwrap(library.cachedTrack(matching: item))
        XCTAssertEqual(library.cachedTracks, [cachedTrack])
        XCTAssertTrue(library.importedTracks.isEmpty)

        let changedItem = WebDAVItem(
            name: item.name,
            url: item.url,
            isDirectory: false,
            contentLength: item.contentLength,
            lastModified: nil,
            eTag: "\"changed\""
        )
        XCTAssertNil(library.cachedTrack(matching: changedItem))
    }

    @MainActor
    func testMusicLibraryDerivesDownloadedFolderStatusFromLocalCache() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EchoVaultDownloadedFolderTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let store = LocalMusicStore(rootURL: rootURL)
        let trackURL = try XCTUnwrap(
            URL(string: "https://dav.example.com/music/Album/Disc%201/Track.m4a")
        )
        let downloadedFolderURL = try XCTUnwrap(
            URL(string: "https://dav.example.com:443/music/Album")
        )
        let nestedFolderURL = try XCTUnwrap(
            URL(string: "https://dav.example.com/music/Album/Disc%201/")
        )
        let parentFolderURL = try XCTUnwrap(URL(string: "https://dav.example.com/music/"))
        let siblingFolderURL = try XCTUnwrap(
            URL(string: "https://dav.example.com/music/Album%202/")
        )
        let differentServerURL = try XCTUnwrap(
            URL(string: "https://other.example.com/music/Album/")
        )
        let item = WebDAVItem(
            name: "Track.m4a",
            url: trackURL,
            isDirectory: false,
            contentLength: nil,
            lastModified: nil,
            eTag: nil
        )
        _ = try await store.cacheDownloadedFile(at: fixtureURL, for: item)
        let suiteName = "MusicLibraryDownloadedFolderTests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let library = MusicLibrary(store: store, userDefaults: userDefaults)
        await library.refresh()

        XCTAssertTrue(library.isFolderDownloaded(at: downloadedFolderURL))
        XCTAssertTrue(library.isFolderDownloaded(at: nestedFolderURL))
        XCTAssertTrue(library.isFolderDownloaded(at: parentFolderURL))
        XCTAssertFalse(library.isFolderDownloaded(at: siblingFolderURL))
        XCTAssertFalse(library.isFolderDownloaded(at: differentServerURL))
        XCTAssertNil(userDefaults.object(forKey: "musicLibrary.downloadedFolderURLs"))

        let reloadedLibrary = MusicLibrary(store: store, userDefaults: userDefaults)
        await reloadedLibrary.refresh()
        XCTAssertTrue(reloadedLibrary.isFolderDownloaded(at: downloadedFolderURL))
        XCTAssertTrue(reloadedLibrary.isFolderDownloaded(at: nestedFolderURL))

        let cachedTrack = try XCTUnwrap(reloadedLibrary.cachedTrack(matching: item))
        try await reloadedLibrary.remove(cachedTrack)

        XCTAssertFalse(reloadedLibrary.isFolderDownloaded(at: downloadedFolderURL))
        XCTAssertFalse(reloadedLibrary.isFolderDownloaded(at: parentFolderURL))
        XCTAssertNil(userDefaults.object(forKey: "musicLibrary.downloadedFolderURLs"))
    }

    func testReusesMetadataIndexWhenFileIsUnchanged() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoVaultMetadataCacheTests-\(UUID().uuidString)", isDirectory: true)
        let reader = CountingMetadataReader()
        let store = LocalMusicStore(rootURL: rootURL, metadataReader: reader)

        let importedSnapshot = try await store.importFiles([fixtureURL]).snapshot
        let reloadedSnapshot = try await store.loadLibrary()
        let callCount = await reader.callCount

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(importedSnapshot.tracks.first?.title, "Indexed Title")
        XCTAssertEqual(reloadedSnapshot.tracks, importedSnapshot.tracks)
    }

    @MainActor
    func testMusicLibraryPersistsAndPrunesFavourites() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EchoVaultFavouriteTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let sourceDirectoryURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectoryURL,
            withIntermediateDirectories: true
        )
        let favouriteSourceURL = sourceDirectoryURL.appendingPathComponent("Favourite.m4a")
        let otherSourceURL = sourceDirectoryURL.appendingPathComponent("Other.m4a")
        try FileManager.default.copyItem(at: fixtureURL, to: favouriteSourceURL)
        try FileManager.default.copyItem(at: fixtureURL, to: otherSourceURL)
        let suiteName = "MusicLibraryFavouriteTests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let store = LocalMusicStore(rootURL: rootURL)
        let library = MusicLibrary(store: store, userDefaults: userDefaults)
        _ = try await library.importFiles([favouriteSourceURL, otherSourceURL])
        let track = try XCTUnwrap(library.tracks.first { $0.filename == "Favourite.m4a" })

        library.addToFavourites(track)
        XCTAssertEqual(library.tracks.count, 2)
        XCTAssertTrue(library.isFavourite(track))
        XCTAssertEqual(library.favouriteTracks, [track])

        let reloadedLibrary = MusicLibrary(store: store, userDefaults: userDefaults)
        await reloadedLibrary.refresh()
        XCTAssertTrue(reloadedLibrary.isFavourite(track))

        try await reloadedLibrary.remove(track)
        XCTAssertFalse(reloadedLibrary.isFavourite(track))
        XCTAssertTrue(reloadedLibrary.favouriteTracks.isEmpty)
        XCTAssertEqual(
            userDefaults.stringArray(forKey: "musicLibrary.favouriteTrackIDs") ?? [],
            []
        )
    }

    func testRemovesOneImportedTrackWithoutRemovingItsSibling() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EchoVaultIndividualRemovalTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let sources = temporaryRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let firstSource = sources.appendingPathComponent("First.m4a")
        let secondSource = sources.appendingPathComponent("Second.m4a")
        try FileManager.default.copyItem(at: fixtureURL, to: firstSource)
        try FileManager.default.copyItem(at: fixtureURL, to: secondSource)
        let store = LocalMusicStore(
            rootURL: temporaryRoot.appendingPathComponent("Store", isDirectory: true)
        )

        let imported = try await store.importFiles([firstSource, secondSource]).snapshot
        let removedTrack = try XCTUnwrap(imported.tracks.first { $0.filename == "First.m4a" })
        let retainedTrack = try XCTUnwrap(imported.tracks.first { $0.filename == "Second.m4a" })

        let remaining = try await store.remove(removedTrack)

        XCTAssertEqual(remaining.tracks, [retainedTrack])
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedTrack.localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedTrack.localURL.path))
    }

    @MainActor
    func testMusicLibraryReportsDuplicatesAndUndoesImport() async throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EchoVaultImportResultTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let library = MusicLibrary(store: LocalMusicStore(rootURL: rootURL))

        let result = try await library.importFiles([fixtureURL, fixtureURL])

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(library.importedTracks.count, 1)

        try await library.undoImport(result)

        XCTAssertTrue(library.tracks.isEmpty)
    }
}
