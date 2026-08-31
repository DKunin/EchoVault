import AVFoundation
import XCTest

@testable import EchoVault

@MainActor
final class AudioPlayerTests: XCTestCase {
    func testControlsLocallyStoredTrack() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let track = AudioTrack(
            title: "Test Tone",
            filename: "test-tone.m4a",
            localURL: fixtureURL,
            origin: .imported
        )
        let player = AudioPlayer()

        player.play(track, in: [track])
        XCTAssertEqual(player.currentTrack, track)
        XCTAssertTrue(player.isPlaying)
        XCTAssertNil(player.errorMessage)

        player.pause()
        XCTAssertFalse(player.isPlaying)

        player.resume()
        XCTAssertTrue(player.isPlaying)

        player.stop()
        XCTAssertNil(player.currentTrack)
        XCTAssertFalse(player.isPlaying)
    }

    func testConfiguresLongFormAudioSessionForAirPlay() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let track = AudioTrack(
            title: "Test Tone",
            filename: "test-tone.m4a",
            localURL: fixtureURL,
            origin: .imported
        )
        let player = AudioPlayer()

        player.play(track, in: [track])

        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.routeSharingPolicy, .longFormAudio)
        player.stop()
    }

    func testRejectsMissingLocalFile() {
        let track = AudioTrack(
            title: "Missing",
            filename: "missing.m4a",
            localURL: URL(fileURLWithPath: "/missing/track.m4a"),
            origin: .imported
        )
        let player = AudioPlayer()

        player.play(track, in: [track])

        XCTAssertNil(player.currentTrack)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(
            player.errorMessage,
            AudioPlayer.PlaybackError.localFileUnavailable.localizedDescription
        )
    }

    func testShuffleUsesRandomizedQueueAndHistory() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults, shuffle: { Array($0.reversed()) })
        player.isShuffleEnabled = true

        player.play(tracks[0], in: tracks)
        player.pause()
        player.playNext()
        player.pause()
        XCTAssertEqual(player.currentTrack?.title, "C")

        player.playNext()
        player.pause()
        XCTAssertEqual(player.currentTrack?.title, "B")

        player.playPrevious()
        player.pause()
        XCTAssertEqual(player.currentTrack?.title, "C")
        player.stop()
    }

    func testPersistsShuffleSetting() throws {
        let suiteName = "AudioPlayerPersistenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults)
        XCTAssertFalse(player.isShuffleEnabled)

        player.toggleShuffle()

        XCTAssertTrue(AudioPlayer(userDefaults: defaults).isShuffleEnabled)
    }

    func testPublishesCurrentTrackFirstInQueue() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerVisibleQueueTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: "playback.shuffleEnabled")
        let player = AudioPlayer(userDefaults: defaults)

        player.play(tracks[0], in: tracks)
        XCTAssertEqual(player.playbackQueue, tracks)

        player.playFromQueue(tracks[2])
        XCTAssertEqual(player.currentTrack, tracks[2])
        XCTAssertEqual(player.playbackQueue, [tracks[2], tracks[0], tracks[1]])
        player.stop()
    }

    func testAddsTrackToEndOfVisibleQueue() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C", "D"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerAppendQueueTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: "playback.shuffleEnabled")
        let player = AudioPlayer(userDefaults: defaults)

        player.play(tracks[1], in: Array(tracks.prefix(3)))
        XCTAssertEqual(player.playbackQueue, [tracks[1], tracks[2], tracks[0]])

        player.addToEndOfQueue(tracks[3])
        XCTAssertEqual(player.playbackQueue, [tracks[1], tracks[2], tracks[0], tracks[3]])

        player.addToEndOfQueue(tracks[2])
        XCTAssertEqual(player.playbackQueue, [tracks[1], tracks[0], tracks[3], tracks[2]])

        player.addToEndOfQueue(tracks[1])
        XCTAssertEqual(player.playbackQueue, [tracks[1], tracks[0], tracks[3], tracks[2]])
        player.stop()
    }

    func testAddingToEmptyQueueStartsTrack() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let track = AudioTrack(
            title: "Queued First",
            filename: "Queued First.m4a",
            localURL: fixtureURL,
            origin: .imported
        )
        let player = AudioPlayer()

        player.addToEndOfQueue(track)

        XCTAssertEqual(player.currentTrack, track)
        XCTAssertEqual(player.playbackQueue, [track])
        player.stop()
    }

    func testAddsTrackToEndOfShuffledQueue() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C", "D"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerQueueShuffleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults, shuffle: { Array($0.reversed()) })
        player.isShuffleEnabled = true

        player.play(tracks[0], in: Array(tracks.prefix(3)))
        XCTAssertEqual(player.playbackQueue, [tracks[0], tracks[2], tracks[1]])

        player.addToEndOfQueue(tracks[3])
        XCTAssertEqual(player.playbackQueue, [tracks[0], tracks[2], tracks[1], tracks[3]])

        player.addToEndOfQueue(tracks[2])
        XCTAssertEqual(player.playbackQueue, [tracks[0], tracks[1], tracks[3], tracks[2]])
        player.stop()
    }

    func testQueuedShuffledHistoryDoesNotDuplicateWhenPlayingPrevious() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerQueueHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults, shuffle: { Array($0.reversed()) })
        player.isShuffleEnabled = true
        player.play(tracks[0], in: tracks)
        player.playNext()
        XCTAssertEqual(player.currentTrack, tracks[2])

        player.addToEndOfQueue(tracks[0])
        XCTAssertEqual(player.playbackQueue, [tracks[2], tracks[1], tracks[0]])
        player.playPrevious()

        XCTAssertEqual(player.currentTrack, tracks[0])
        XCTAssertEqual(player.playbackQueue, [tracks[0], tracks[2], tracks[1]])
        player.stop()
    }

    func testQueuesTrackNextAndUndoesTheAction() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerPlayNextTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults)

        player.play(tracks[0], in: tracks)
        player.playNext(tracks[2])

        XCTAssertEqual(player.playbackQueue, [tracks[0], tracks[2], tracks[1]])
        XCTAssertEqual(player.queueActionFeedback?.canUndo, true)

        player.undoLastQueueAction()

        XCTAssertEqual(player.playbackQueue, tracks)
        XCTAssertNil(player.queueActionFeedback)
        player.stop()
    }

    func testQueuesFolderNextInOrderAndUndoesAsOneAction() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C", "D", "E"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerFolderNextTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults)
        player.play(tracks[1], in: Array(tracks.prefix(3)))

        player.playNext([tracks[3], tracks[4], tracks[2], tracks[3]], from: "Folder")

        XCTAssertEqual(
            player.playbackQueue,
            [tracks[1], tracks[3], tracks[4], tracks[2], tracks[0]]
        )
        XCTAssertEqual(player.queueActionFeedback?.canUndo, true)

        player.undoLastQueueAction()

        XCTAssertEqual(player.playbackQueue, [tracks[1], tracks[2], tracks[0]])
        player.stop()
    }

    func testAddsFolderToEndOfShuffledQueueInFolderOrder() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C", "D", "E"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerFolderAppendTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults, shuffle: { Array($0.reversed()) })
        player.isShuffleEnabled = true
        player.play(tracks[0], in: Array(tracks.prefix(3)))

        player.addToEndOfQueue([tracks[3], tracks[4], tracks[1]], from: "Folder")

        XCTAssertEqual(
            player.playbackQueue,
            [tracks[0], tracks[2], tracks[3], tracks[4], tracks[1]]
        )
        player.stop()
    }

    func testReordersRemovesAndClearsUpcomingQueue() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C", "D"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerQueueEditingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults)
        player.play(tracks[0], in: tracks)

        player.moveUpcomingTracks(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(player.playbackQueue, [tracks[0], tracks[3], tracks[1], tracks[2]])

        player.removeUpcomingTracks(atOffsets: IndexSet(integer: 1))
        XCTAssertEqual(player.playbackQueue, [tracks[0], tracks[3], tracks[2]])

        player.clearUpcomingQueue()
        XCTAssertEqual(player.playbackQueue, [tracks[0]])
        player.stop()
    }

    func testRemovesSpecificUpcomingTrackFromShuffledQueueWithoutChangingCurrentTrack() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerSpecificRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(
            userDefaults: defaults,
            shuffle: { Array($0.reversed()) }
        )
        player.isShuffleEnabled = true
        player.play(tracks[0], in: tracks)

        player.removeUpcomingTrack(tracks[2])

        XCTAssertEqual(player.currentTrack, tracks[0])
        XCTAssertEqual(player.playbackQueue, [tracks[0], tracks[1]])

        player.removeUpcomingTrack(tracks[0])
        XCTAssertEqual(player.playbackQueue, [tracks[0], tracks[1]])
        player.stop()
    }

    func testRemovingStoredTrackAlsoRemovesItFromPlaybackState() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let player = AudioPlayer()
        player.play(tracks[0], in: tracks)
        player.playFromQueue(tracks[1])
        XCTAssertEqual(player.playbackHistory, [tracks[0]])

        player.removeTrackFromPlayback(tracks[0])

        XCTAssertEqual(player.playbackQueue, [tracks[1], tracks[2]])
        XCTAssertTrue(player.playbackHistory.isEmpty)
        player.stop()
    }

    func testPublishesPlaybackHistory() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerHistoryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults)

        player.play(tracks[0], in: tracks)
        player.playNext()
        player.playFromQueue(tracks[2])

        XCTAssertEqual(player.playbackHistory, [tracks[0], tracks[1]])
        player.stop()
    }

    func testStartsCollectionInOrderOrShuffled() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerCollectionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let player = AudioPlayer(userDefaults: defaults, shuffle: { Array($0.reversed()) })

        player.playShuffled(tracks)
        XCTAssertEqual(player.currentTrack, tracks[2])
        XCTAssertTrue(player.isShuffleEnabled)

        player.playInOrder(tracks)
        XCTAssertEqual(player.currentTrack, tracks[0])
        XCTAssertFalse(player.isShuffleEnabled)
        player.stop()
    }

    func testPersistsRepeatModeAndStopsQueueWrappingWhenOff() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let tracks = ["A", "B", "C"].map { title in
            AudioTrack(
                title: title,
                filename: "\(title).m4a",
                localURL: fixtureURL,
                origin: .imported
            )
        }
        let suiteName = "AudioPlayerRepeatTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(PlaybackRepeatMode.off.rawValue, forKey: "playback.repeatMode")
        let player = AudioPlayer(userDefaults: defaults)

        player.play(tracks[1], in: tracks)
        XCTAssertEqual(player.playbackQueue, [tracks[1], tracks[2]])

        player.playFromQueue(tracks[2])
        player.playNext()
        XCTAssertEqual(player.currentTrack, tracks[2])

        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertEqual(player.playbackQueue, [tracks[2], tracks[0], tracks[1]])
        XCTAssertEqual(AudioPlayer(userDefaults: defaults).repeatMode, .all)
        player.stop()
    }

    func testProgressObserverRunsOnlyWhileRequested() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let track = AudioTrack(
            title: "Test Tone",
            filename: "test-tone.m4a",
            localURL: fixtureURL,
            origin: .imported
        )
        let player = AudioPlayer()
        player.play(track, in: [track])

        XCTAssertFalse(player.isProgressObservationActive)
        player.beginProgressUpdates()
        player.beginProgressUpdates()
        XCTAssertTrue(player.isProgressObservationActive)

        player.endProgressUpdates()
        XCTAssertTrue(player.isProgressObservationActive)
        player.endProgressUpdates()
        XCTAssertFalse(player.isProgressObservationActive)
        player.stop()
    }

    func testProgressObserverPausesOutsideActiveScene() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "test-tone", withExtension: "m4a")
        )
        let track = AudioTrack(
            title: "Test Tone",
            filename: "test-tone.m4a",
            localURL: fixtureURL,
            origin: .imported
        )
        let player = AudioPlayer()
        player.play(track, in: [track])
        player.beginProgressUpdates()

        XCTAssertTrue(player.isProgressObservationActive)
        player.setProgressUpdatesEnabled(false)
        XCTAssertFalse(player.isProgressObservationActive)

        player.setProgressUpdatesEnabled(true)
        XCTAssertTrue(player.isProgressObservationActive)
        player.endProgressUpdates()
        player.stop()
    }

    func testIPhone13ProContentAreaUsesCompactNowPlayingLayout() {
        let layout = NowPlayingLayoutMetrics(
            availableSize: CGSize(width: 390, height: 730)
        )

        XCTAssertTrue(layout.isCompactHeight)
        XCTAssertEqual(layout.artworkSize, 300)
        XCTAssertEqual(layout.verticalSpacing, 16)
        XCTAssertEqual(layout.playButtonSize, 64)
        XCTAssertEqual(layout.bottomPadding, 12)
    }

    func testTallNowPlayingContentAreaKeepsRegularLayout() {
        let layout = NowPlayingLayoutMetrics(
            availableSize: CGSize(width: 430, height: 800)
        )

        XCTAssertFalse(layout.isCompactHeight)
        XCTAssertEqual(layout.artworkSize, 374)
        XCTAssertEqual(layout.verticalSpacing, 24)
        XCTAssertEqual(layout.playButtonSize, 72)
    }
}
