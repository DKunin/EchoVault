import XCTest

@testable import EchoVault

@MainActor
final class MusicAlbumTests: XCTestCase {
    func testGroupsMetadataAlbumsAndFolderFallbacks() throws {
        let taggedOne = track(
            title: "Second",
            artist: "Artist",
            album: "Shared Album",
            folder: "Folder A",
            path: "/tmp/second.m4a"
        )
        let taggedTwo = track(
            title: "First",
            artist: "Artist",
            album: "shared album",
            folder: "Folder B",
            path: "/tmp/first.m4a"
        )
        let folderTrack = track(
            title: "Folder Track",
            artist: "Another Artist",
            album: nil,
            folder: "Folder A",
            path: "/tmp/folder.m4a"
        )
        let library = MusicLibrary.preview(tracks: [taggedOne, taggedTwo, folderTrack])

        let albums = library.albums

        XCTAssertEqual(albums.count, 2)
        let metadataAlbum = try XCTUnwrap(albums.first { $0.id.hasPrefix("metadata:") })
        XCTAssertEqual(metadataAlbum.tracks.map(\.title), ["First", "Second"])
        XCTAssertEqual(metadataAlbum.artist, "Artist")
        XCTAssertEqual(albums.first { $0.id.hasPrefix("folder:") }?.title, "Folder A")
    }

    func testGroupsTracksIntoTheirPhysicalFoldersRegardlessOfAlbumMetadata() {
        let tracks = [
            AudioTrack(
                title: "Disc One",
                artist: "Artist",
                albumTitle: "Album",
                folderName: "Disc 1",
                folderIdentifier: "Collection/Disc 1",
                filename: "one.m4a",
                localURL: URL(fileURLWithPath: "/tmp/one.m4a"),
                origin: .imported
            ),
            AudioTrack(
                title: "Disc Two",
                artist: "Artist",
                albumTitle: "Album",
                folderName: "Disc 2",
                folderIdentifier: "Collection/Disc 2",
                filename: "two.m4a",
                localURL: URL(fileURLWithPath: "/tmp/two.m4a"),
                origin: .imported
            ),
        ]

        let folders = MusicLibrary.preview(tracks: tracks).folders

        XCTAssertEqual(folders.map(\.title), ["Disc 1", "Disc 2"])
        XCTAssertEqual(folders.map(\.path), ["Collection/Disc 1", "Collection/Disc 2"])
    }

    private func track(
        title: String,
        artist: String,
        album: String?,
        folder: String?,
        path: String
    ) -> AudioTrack {
        AudioTrack(
            title: title,
            artist: artist,
            albumTitle: album,
            folderName: folder,
            filename: URL(fileURLWithPath: path).lastPathComponent,
            localURL: URL(fileURLWithPath: path),
            origin: .imported
        )
    }
}
