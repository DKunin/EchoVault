import XCTest

@testable import EchoVault

@MainActor
final class PlaylistStoreTests: XCTestCase {
    private let storageKey = "test.playlists.snapshot"

    func testMutationsPersistAutomaticallyAndPreserveOrder() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = PlaylistStore(
            userDefaults: userDefaults,
            storageKey: storageKey,
            now: { timestamp }
        )
        let playlistID = try store.createPlaylist(named: "  Road Trip  ")
        let first = makeTrack(title: "First")
        let second = makeTrack(title: "Second")

        XCTAssertEqual(
            try store.add([.track(first), .track(second), .track(first)], to: playlistID),
            2
        )
        try store.moveItems(from: IndexSet(integer: 1), to: 0, in: playlistID)

        let reloaded = PlaylistStore(userDefaults: userDefaults, storageKey: storageKey)
        let playlist = try XCTUnwrap(reloaded.playlist(id: playlistID))
        XCTAssertEqual(playlist.name, "Road Trip")
        XCTAssertEqual(playlist.items.map(\.title), ["Second", "First"])
        XCTAssertEqual(playlist.updatedAt, timestamp)

        try reloaded.removeItems(at: IndexSet(integer: 0), from: playlistID)
        let afterRemoval = PlaylistStore(userDefaults: userDefaults, storageKey: storageKey)
        XCTAssertEqual(afterRemoval.playlist(id: playlistID)?.items.map(\.title), ["First"])
    }

    func testNamesMustBeNonemptyAndUnique() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = PlaylistStore(userDefaults: userDefaults, storageKey: storageKey)

        XCTAssertThrowsError(try store.createPlaylist(named: "   ")) { error in
            XCTAssertEqual(error as? PlaylistStoreError, .emptyName)
        }
        _ = try store.createPlaylist(named: "Focus")
        XCTAssertThrowsError(try store.createPlaylist(named: "fócus")) { error in
            XCTAssertEqual(error as? PlaylistStoreError, .duplicateName)
        }
    }

    func testFolderAndTrackEntriesResolveInPlaylistOrderWithoutDuplicatePlayback() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = PlaylistStore(userDefaults: userDefaults, storageKey: storageKey)
        let playlistID = try store.createPlaylist(named: "Mixed")
        let first = makeTrack(title: "First", folder: "Folder")
        let second = makeTrack(title: "Second", folder: "Folder")
        let third = makeTrack(title: "Third", folder: "Other")
        let folder = MusicFolder(groupingKey: "folder-id", tracks: [second, first])

        _ = try store.add([.folder(folder), .track(first), .track(third)], to: playlistID)
        let playlist = try XCTUnwrap(store.playlist(id: playlistID))

        XCTAssertEqual(
            playlist.resolvedTracks(
                availableTracks: [first, second, third],
                availableFolders: [folder]
            ).map(\.title),
            folder.tracks.map(\.title) + [third.title]
        )
    }

    func testDeletePersists() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = PlaylistStore(userDefaults: userDefaults, storageKey: storageKey)
        let playlistID = try store.createPlaylist(named: "Temporary")

        try store.deletePlaylist(id: playlistID)

        XCTAssertTrue(store.playlists.isEmpty)
        XCTAssertTrue(
            PlaylistStore(userDefaults: userDefaults, storageKey: storageKey).playlists.isEmpty
        )
    }

    func testRebasesWebDAVPlaylistReferencesWithEndpointMigration() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = PlaylistStore(userDefaults: userDefaults, storageKey: storageKey)
        let playlistID = try store.createPlaylist(named: "Migrated")
        let oldRemoteURL = try XCTUnwrap(
            URL(string: "http://192.0.2.42:4243/old/Album/Track.m4a")
        )
        let oldTrack = makeWebDAVTrack(remoteURL: oldRemoteURL)
        let oldFolder = MusicFolder(groupingKey: "old-folder", tracks: [oldTrack])
        _ = try store.add([.track(oldTrack), .folder(oldFolder)], to: playlistID)
        let migration = WebDAVEndpointMigration(
            sourceRootURL: try XCTUnwrap(URL(string: "http://192.0.2.42:4243/old/")),
            destinationRootURL: try XCTUnwrap(URL(string: "https://dav.example.com/music/"))
        )

        try store.rebaseWebDAVReferences(using: [migration])

        let newRemoteURL = try XCTUnwrap(
            URL(string: "https://dav.example.com/music/Album/Track.m4a")
        )
        let newTrack = makeWebDAVTrack(remoteURL: newRemoteURL)
        let newFolder = MusicFolder(groupingKey: "new-folder", tracks: [newTrack])
        let playlist = try XCTUnwrap(store.playlist(id: playlistID))
        XCTAssertEqual(
            playlist.items.map(\.referenceID),
            [newTrack.playlistReferenceID, newFolder.playlistReferenceID]
        )
        XCTAssertEqual(
            playlist.resolvedTracks(availableTracks: [newTrack], availableFolders: [newFolder]),
            [newTrack]
        )
        XCTAssertEqual(
            PlaylistStore(userDefaults: userDefaults, storageKey: storageKey)
                .playlist(id: playlistID)?.items,
            playlist.items
        )
    }

    func testImportCreatesPersistentCopiesWithoutOverwritingMatchingNames() throws {
        let (userDefaults, suiteName) = try makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let timestamp = Date(timeIntervalSince1970: 1_900_000_000)
        let store = PlaylistStore(
            userDefaults: userDefaults,
            storageKey: storageKey,
            now: { timestamp }
        )
        _ = try store.createPlaylist(named: "Road Trip")
        let importedItem = PlaylistItem(draft: .track(makeTrack(title: "First")))
        let externalPlaylist = MusicPlaylist(
            name: "Road Trip",
            items: [importedItem]
        )

        let firstImportID = try store.importPlaylist(externalPlaylist)
        let secondImportID = try store.importPlaylist(externalPlaylist)

        let firstImport = try XCTUnwrap(store.playlist(id: firstImportID))
        let secondImport = try XCTUnwrap(store.playlist(id: secondImportID))
        XCTAssertEqual(firstImport.name, "Road Trip (Imported)")
        XCTAssertEqual(secondImport.name, "Road Trip (Imported 2)")
        XCTAssertNotEqual(firstImport.id, externalPlaylist.id)
        XCTAssertNotEqual(firstImport.items.first?.id, importedItem.id)
        XCTAssertEqual(firstImport.createdAt, timestamp)
        XCTAssertEqual(
            PlaylistStore(userDefaults: userDefaults, storageKey: storageKey).playlists.count,
            3
        )
    }

    private func makeUserDefaults() throws -> (UserDefaults, String) {
        let suiteName = "PlaylistStoreTests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func makeTrack(
        title: String,
        folder: String? = nil
    ) -> AudioTrack {
        AudioTrack(
            title: title,
            folderName: folder,
            folderIdentifier: folder,
            filename: "\(title).m4a",
            localURL: URL(fileURLWithPath: "/tmp/\(title).m4a"),
            origin: .imported
        )
    }

    private func makeWebDAVTrack(remoteURL: URL) -> AudioTrack {
        AudioTrack(
            title: "Track",
            folderName: "Album",
            folderIdentifier: remoteURL.deletingLastPathComponent().absoluteString,
            filename: remoteURL.lastPathComponent,
            localURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).m4a"),
            origin: .webDAV,
            remoteURL: remoteURL
        )
    }
}
