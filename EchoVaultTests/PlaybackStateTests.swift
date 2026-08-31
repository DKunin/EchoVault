import XCTest

@testable import EchoVault

@MainActor
final class PlaybackStateTests: XCTestCase {
    func testStoreRoundTripsAndClearsSnapshot() throws {
        let defaults = try makeUserDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let snapshot = PlaybackStateSnapshot(
            queueTrackIDs: ["A", "B"],
            currentTrackID: "B",
            shuffledUpcomingTrackIDs: ["A"],
            shuffleHistoryTrackIDs: ["C"],
            playbackHistoryTrackIDs: ["A"],
            elapsedTime: 42.5,
            wasPlaying: true,
            isShuffleEnabled: true,
            repeatMode: .one
        )

        try store.save(snapshot)

        XCTAssertEqual(try store.load(), snapshot)

        store.clear()
        XCTAssertNil(try store.load())
    }

    func testRestoresPausedQueuePositionSettingsAndHistory() throws {
        let defaults = try makeUserDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let tracks = try makeTracks(named: ["A", "B", "C"])
        try store.save(
            PlaybackStateSnapshot(
                queueTrackIDs: tracks.map(\.id),
                currentTrackID: tracks[1].id,
                shuffledUpcomingTrackIDs: [],
                shuffleHistoryTrackIDs: [tracks[0].id],
                playbackHistoryTrackIDs: [tracks[0].id],
                elapsedTime: 0.2,
                wasPlaying: false,
                isShuffleEnabled: false,
                repeatMode: .all
            )
        )
        let player = AudioPlayer(
            userDefaults: defaults,
            playbackStateStore: store
        )

        XCTAssertTrue(player.restorePlaybackState(from: tracks))

        XCTAssertEqual(player.currentTrack, tracks[1])
        XCTAssertEqual(player.playbackQueue, [tracks[1], tracks[2], tracks[0]])
        XCTAssertEqual(player.playbackHistory, [tracks[0]])
        XCTAssertEqual(player.elapsedTime, 0.2, accuracy: 0.001)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isShuffleEnabled)
        XCTAssertEqual(player.repeatMode, .all)

        player.checkpointPlaybackState()
        player.pause()
        XCTAssertEqual(try XCTUnwrap(store.load()).elapsedTime, 0.2, accuracy: 0.001)
        player.stop()
    }

    func testRestoresPlayingShuffledQueueInSavedOrder() throws {
        let defaults = try makeUserDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let tracks = try makeTracks(named: ["A", "B", "C"])
        try store.save(
            PlaybackStateSnapshot(
                queueTrackIDs: tracks.map(\.id),
                currentTrackID: tracks[1].id,
                shuffledUpcomingTrackIDs: [tracks[0].id, tracks[2].id],
                shuffleHistoryTrackIDs: [tracks[2].id],
                playbackHistoryTrackIDs: [tracks[0].id],
                elapsedTime: 0.1,
                wasPlaying: true,
                isShuffleEnabled: true,
                repeatMode: .off
            )
        )
        let player = AudioPlayer(
            userDefaults: defaults,
            shuffle: { Array($0.reversed()) },
            playbackStateStore: store
        )

        XCTAssertTrue(player.restorePlaybackState(from: tracks))

        XCTAssertEqual(player.currentTrack, tracks[1])
        XCTAssertEqual(player.playbackQueue, [tracks[1], tracks[0], tracks[2]])
        XCTAssertEqual(player.elapsedTime, 0.1, accuracy: 0.001)
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.isShuffleEnabled)
        XCTAssertEqual(player.repeatMode, .off)
        player.stop()
    }

    func testRestoreSkipsMissingCurrentTrackAndContinuesWithNextAvailableTrack() throws {
        let defaults = try makeUserDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let tracks = try makeTracks(named: ["A", "C"])
        let missingTrackID = "/missing/B.m4a"
        try store.save(
            PlaybackStateSnapshot(
                queueTrackIDs: [tracks[0].id, missingTrackID, tracks[1].id],
                currentTrackID: missingTrackID,
                shuffledUpcomingTrackIDs: [],
                shuffleHistoryTrackIDs: [missingTrackID],
                playbackHistoryTrackIDs: [tracks[0].id, missingTrackID],
                elapsedTime: 12,
                wasPlaying: false,
                isShuffleEnabled: false,
                repeatMode: .off
            )
        )
        let player = AudioPlayer(
            userDefaults: defaults,
            playbackStateStore: store
        )

        XCTAssertTrue(player.restorePlaybackState(from: tracks))

        XCTAssertEqual(player.currentTrack, tracks[1])
        XCTAssertEqual(player.playbackQueue, [tracks[1]])
        XCTAssertEqual(player.playbackHistory, [tracks[0]])
        XCTAssertEqual(player.elapsedTime, 0)
        player.stop()
    }

    func testRestoreDiscardsUnsupportedSnapshotVersion() throws {
        let defaults = try makeUserDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let tracks = try makeTracks(named: ["A"])
        try store.save(
            PlaybackStateSnapshot(
                version: PlaybackStateSnapshot.currentVersion + 1,
                queueTrackIDs: tracks.map(\.id),
                currentTrackID: tracks[0].id,
                shuffledUpcomingTrackIDs: [],
                shuffleHistoryTrackIDs: [],
                playbackHistoryTrackIDs: [],
                elapsedTime: 0,
                wasPlaying: false,
                isShuffleEnabled: false,
                repeatMode: .all
            )
        )
        let player = AudioPlayer(
            userDefaults: defaults,
            playbackStateStore: store
        )

        XCTAssertFalse(player.restorePlaybackState(from: tracks))

        XCTAssertNil(player.currentTrack)
        XCTAssertNil(try store.load())
    }

    func testPlaybackChangesPersistImmediatelyAndStopClearsSnapshot() throws {
        let defaults = try makeUserDefaults()
        let store = PlaybackStateStore(userDefaults: defaults)
        let tracks = try makeTracks(named: ["A", "B"])
        let player = AudioPlayer(
            userDefaults: defaults,
            playbackStateStore: store
        )

        player.play(tracks[0], in: tracks)

        var snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.currentTrackID, tracks[0].id)
        XCTAssertEqual(snapshot.queueTrackIDs, tracks.map(\.id))
        XCTAssertTrue(snapshot.wasPlaying)

        player.pause()

        snapshot = try XCTUnwrap(store.load())
        XCTAssertFalse(snapshot.wasPlaying)

        player.stop()

        XCTAssertNil(try store.load())
    }

    private func makeUserDefaults() throws -> UserDefaults {
        try XCTUnwrap(
            UserDefaults(suiteName: "PlaybackStateTests-\(UUID().uuidString)")
        )
    }

    private func makeTracks(named titles: [String]) throws -> [AudioTrack] {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EchoVaultPlaybackStateTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try FileManager.default.removeItem(at: rootURL)
        }

        return try titles.map { title in
            let destinationURL = rootURL.appendingPathComponent("\(title).m4a")
            try FileManager.default.copyItem(at: fixtureURL, to: destinationURL)
            return AudioTrack(
                title: title,
                filename: destinationURL.lastPathComponent,
                localURL: destinationURL,
                origin: .imported
            )
        }
    }
}
