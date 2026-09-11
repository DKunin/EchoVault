import XCTest

@testable import EchoVault

@MainActor
final class PlaylistDocumentTests: XCTestCase {
    func testRoundTripUsesWebDAVReferencesAcrossDifferentLocalStoragePaths() throws {
        let sourceTrack = makeWebDAVTrack(
            title: "One",
            remotePath: "Singles/One.mp3",
            localRoot: "/mac-cache"
        )
        let sourceFolderTrack = makeWebDAVTrack(
            title: "Two",
            remotePath: "Album/Two.mp3",
            localRoot: "/mac-cache"
        )
        let sourceFolder = MusicFolder(
            groupingKey: try XCTUnwrap(
                sourceFolderTrack.remoteURL?.deletingLastPathComponent().absoluteString
            ),
            tracks: [sourceFolderTrack]
        )
        let playlist = MusicPlaylist(
            name: "Road/Trip",
            items: [
                PlaylistItem(
                    draft: PlaylistItemDraft(
                        kind: .track,
                        referenceID: sourceTrack.id,
                        title: sourceTrack.title,
                        subtitle: sourceTrack.artist
                    )
                ),
                PlaylistItem(
                    draft: PlaylistItemDraft(
                        kind: .folder,
                        referenceID: sourceFolder.id,
                        title: sourceFolder.title,
                        subtitle: sourceFolder.path
                    )
                ),
            ]
        )

        let exported = PlaylistDocument(
            playlist: playlist,
            availableTracks: [sourceTrack, sourceFolderTrack],
            availableFolders: [sourceFolder]
        )
        XCTAssertEqual(exported.playlist.items[0].referenceID, sourceTrack.playlistReferenceID)
        XCTAssertEqual(exported.playlist.items[1].referenceID, sourceFolder.playlistReferenceID)
        XCTAssertEqual(PlaylistDocument.defaultFilename(for: playlist), "Road-Trip")

        let imported = try PlaylistDocument(data: exported.encodedData())
        let targetTrack = makeWebDAVTrack(
            title: "One",
            remotePath: "Singles/One.mp3",
            localRoot: "/ios-cache"
        )
        let targetFolderTrack = makeWebDAVTrack(
            title: "Two",
            remotePath: "Album/Two.mp3",
            localRoot: "/ios-cache"
        )
        let targetFolder = MusicFolder(
            groupingKey: try XCTUnwrap(
                targetFolderTrack.remoteURL?.deletingLastPathComponent().absoluteString
            ),
            tracks: [targetFolderTrack]
        )

        XCTAssertEqual(
            imported.playlist.resolvedTracks(
                availableTracks: [targetTrack, targetFolderTrack],
                availableFolders: [targetFolder]
            ).map(\.title),
            ["One", "Two"]
        )
        XCTAssertEqual(
            imported.playlist.unavailableItemCount(
                availableTracks: [targetTrack, targetFolderTrack],
                availableFolders: [targetFolder]
            ),
            0
        )
    }

    func testUnsupportedVersionIsRejected() throws {
        let playlist = MusicPlaylist(name: "Version")
        let document = PlaylistDocument(
            playlist: playlist,
            availableTracks: [],
            availableFolders: []
        )
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: document.encodedData()) as? [String: Any]
        )
        payload["version"] = 99
        let data = try JSONSerialization.data(withJSONObject: payload)

        XCTAssertThrowsError(try PlaylistDocument(data: data)) { error in
            XCTAssertEqual(error as? PlaylistDocumentError, .unsupportedVersion(99))
        }
    }

    private func makeWebDAVTrack(
        title: String,
        remotePath: String,
        localRoot: String
    ) -> AudioTrack {
        AudioTrack(
            title: title,
            artist: "Artist",
            filename: URL(fileURLWithPath: remotePath).lastPathComponent,
            localURL: URL(fileURLWithPath: localRoot).appendingPathComponent(title),
            origin: .webDAV,
            remoteURL: URL(string: "https://dav.example.com/music/\(remotePath)")
        )
    }
}
