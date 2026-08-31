import Foundation

struct PlaybackStateSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let queueTrackIDs: [AudioTrack.ID]
    let currentTrackID: AudioTrack.ID
    let shuffledUpcomingTrackIDs: [AudioTrack.ID]
    let shuffleHistoryTrackIDs: [AudioTrack.ID]
    let playbackHistoryTrackIDs: [AudioTrack.ID]
    let elapsedTime: TimeInterval
    let wasPlaying: Bool
    let isShuffleEnabled: Bool
    let repeatMode: PlaybackRepeatMode

    init(
        version: Int = Self.currentVersion,
        queueTrackIDs: [AudioTrack.ID],
        currentTrackID: AudioTrack.ID,
        shuffledUpcomingTrackIDs: [AudioTrack.ID],
        shuffleHistoryTrackIDs: [AudioTrack.ID],
        playbackHistoryTrackIDs: [AudioTrack.ID],
        elapsedTime: TimeInterval,
        wasPlaying: Bool,
        isShuffleEnabled: Bool,
        repeatMode: PlaybackRepeatMode
    ) {
        self.version = version
        self.queueTrackIDs = queueTrackIDs
        self.currentTrackID = currentTrackID
        self.shuffledUpcomingTrackIDs = shuffledUpcomingTrackIDs
        self.shuffleHistoryTrackIDs = shuffleHistoryTrackIDs
        self.playbackHistoryTrackIDs = playbackHistoryTrackIDs
        self.elapsedTime = elapsedTime
        self.wasPlaying = wasPlaying
        self.isShuffleEnabled = isShuffleEnabled
        self.repeatMode = repeatMode
    }
}

struct PlaybackStateStore {
    private static let defaultStorageKey = "playback.session.v1"

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = Self.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func load() throws -> PlaybackStateSnapshot? {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return nil
        }
        return try decoder.decode(PlaybackStateSnapshot.self, from: data)
    }

    func save(_ snapshot: PlaybackStateSnapshot) throws {
        userDefaults.set(try encoder.encode(snapshot), forKey: storageKey)
    }

    func clear() {
        userDefaults.removeObject(forKey: storageKey)
    }
}
