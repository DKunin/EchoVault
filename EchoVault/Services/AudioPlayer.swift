import AVFoundation
import MediaPlayer
import OSLog
import Observation
import UIKit

private final class NowPlayingArtworkProvider: @unchecked Sendable {
    let image: UIImage

    init(image: UIImage) {
        self.image = image
    }

    func image(for _: CGSize) -> UIImage {
        image
    }
}

private final class AudioPlayerResources: @unchecked Sendable {
    let player = AVPlayer()
    var timeObserver: Any?
    var playbackStateTimeObserver: Any?
    var notificationTokens: [NSObjectProtocol] = []
    var remoteTargets: [(MPRemoteCommand, Any)] = []
    var playbackEndObserver: NSObjectProtocol?
    var playbackFailureObserver: NSObjectProtocol?
    var itemStatusObservation: NSKeyValueObservation?
    var itemDurationObservation: NSKeyValueObservation?
    var nowPlayingArtworkTrackID: AudioTrack.ID?
    var nowPlayingArtwork: MPMediaItemArtwork?
    var nowPlayingArtworkProvider: NowPlayingArtworkProvider?
    var artworkLoadTask: Task<Void, Never>?
    var progressObserverClients = 0
    var areProgressUpdatesEnabled = true
    var isAudioSessionConfigured = false
    var isAudioSessionActive = false

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let playbackStateTimeObserver {
            player.removeTimeObserver(playbackStateTimeObserver)
        }
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        if let playbackFailureObserver {
            NotificationCenter.default.removeObserver(playbackFailureObserver)
        }
        remoteTargets.forEach { command, target in
            command.removeTarget(target)
        }
        artworkLoadTask?.cancel()
    }
}

struct QueueActionFeedback: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let canUndo: Bool
}

enum PlaybackRepeatMode: String, CaseIterable, Codable, Sendable {
    case off
    case all
    case one

    var systemImage: String {
        self == .one ? "repeat.1" : "repeat"
    }

    var accessibilityValue: String {
        switch self {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    var next: PlaybackRepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

@MainActor
@Observable
final class AudioPlayer {
    enum PlaybackError: LocalizedError {
        case localFileUnavailable
        case itemFailed(String)

        var errorDescription: String? {
            switch self {
            case .localFileUnavailable:
                return "The local audio file is no longer available."
            case .itemFailed(let message):
                return "Playback failed: \(message)"
            }
        }
    }

    private(set) var currentTrack: AudioTrack?
    private(set) var isPlaying = false
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var playbackQueue: [AudioTrack] = []
    private(set) var playbackHistory: [AudioTrack] = []
    private(set) var queueActionFeedback: QueueActionFeedback?
    var isShuffleEnabled: Bool {
        didSet {
            userDefaults.set(isShuffleEnabled, forKey: Self.shuffleSettingKey)
            resetShuffleState()
            refreshPublishedQueue()
            updateNowPlayingInfo()
        }
    }
    var repeatMode: PlaybackRepeatMode {
        didSet {
            userDefaults.set(repeatMode.rawValue, forKey: Self.repeatSettingKey)
            refreshPublishedQueue()
            updateRemoteCommandAvailability()
            updateNowPlayingInfo()
        }
    }

    @ObservationIgnored private let resources = AudioPlayerResources()
    @ObservationIgnored private var queue: [AudioTrack] = []
    @ObservationIgnored private var shuffledUpcoming: [AudioTrack] = []
    @ObservationIgnored private var shuffleHistory: [AudioTrack] = []
    @ObservationIgnored private var queueUndoSnapshot: QueueUndoSnapshot?
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let shuffle: ([AudioTrack]) -> [AudioTrack]
    @ObservationIgnored private let playbackStateStore: PlaybackStateStore?
    @ObservationIgnored private var isRestoringPlaybackState = false
    @ObservationIgnored private var didAttemptPlaybackStateRestore = false
    @ObservationIgnored private var pendingSeekID: UUID?
    @ObservationIgnored private var pendingSeekPosition: TimeInterval?

    private static let shuffleSettingKey = "playback.shuffleEnabled"
    private static let repeatSettingKey = "playback.repeatMode"
    private static let playbackStateLogger = Logger(
        subsystem: "com.example.EchoVault",
        category: "PlaybackState"
    )

    private struct QueueUndoSnapshot {
        let currentTrackID: AudioTrack.ID
        let queue: [AudioTrack]
        let shuffledUpcoming: [AudioTrack]
    }

    private enum CollectionQueuePlacement {
        case next
        case end
    }

    private var player: AVPlayer {
        resources.player
    }

    var isProgressObservationActive: Bool {
        resources.timeObserver != nil
    }

    init(
        userDefaults: UserDefaults = .standard,
        shuffle: @escaping ([AudioTrack]) -> [AudioTrack] = { $0.shuffled() },
        playbackStateStore: PlaybackStateStore? = nil
    ) {
        self.userDefaults = userDefaults
        self.shuffle = shuffle
        self.playbackStateStore = playbackStateStore
        isShuffleEnabled = userDefaults.bool(forKey: Self.shuffleSettingKey)
        repeatMode =
            userDefaults.string(forKey: Self.repeatSettingKey)
            .flatMap(PlaybackRepeatMode.init(rawValue:)) ?? .all
        installNotificationObservers()
        installRemoteCommands()
    }

    @discardableResult
    func restorePlaybackState(from availableTracks: [AudioTrack]) -> Bool {
        guard !didAttemptPlaybackStateRestore else {
            return false
        }
        didAttemptPlaybackStateRestore = true
        guard currentTrack == nil, let playbackStateStore else {
            return false
        }

        let snapshot: PlaybackStateSnapshot
        do {
            guard let savedSnapshot = try playbackStateStore.load() else {
                return false
            }
            snapshot = savedSnapshot
        } catch {
            Self.playbackStateLogger.error(
                "Could not decode saved playback state: \(error.localizedDescription, privacy: .public)"
            )
            playbackStateStore.clear()
            return false
        }

        guard snapshot.version == PlaybackStateSnapshot.currentVersion,
            !snapshot.queueTrackIDs.isEmpty,
            !snapshot.currentTrackID.isEmpty,
            snapshot.elapsedTime.isFinite,
            snapshot.elapsedTime >= 0
        else {
            Self.playbackStateLogger.error("Discarded an invalid saved playback state")
            playbackStateStore.clear()
            return false
        }

        var tracksByID: [AudioTrack.ID: AudioTrack] = [:]
        for track in availableTracks
        where FileManager.default.fileExists(atPath: track.localURL.path) {
            tracksByID[track.id] = track
        }

        func resolveTracks(_ trackIDs: [AudioTrack.ID]) -> [AudioTrack] {
            var resolvedTrackIDs = Set<AudioTrack.ID>()
            return trackIDs.compactMap { trackID in
                guard resolvedTrackIDs.insert(trackID).inserted else {
                    return nil
                }
                return tracksByID[trackID]
            }
        }

        var restoredQueue = resolveTracks(snapshot.queueTrackIDs)
        let savedCurrentTrack = tracksByID[snapshot.currentTrackID]
        if let savedCurrentTrack,
            !restoredQueue.contains(where: { $0.id == savedCurrentTrack.id })
        {
            restoredQueue.insert(savedCurrentTrack, at: 0)
        }
        let fallbackTrackIDs: [AudioTrack.ID]
        if snapshot.isShuffleEnabled {
            fallbackTrackIDs = snapshot.shuffledUpcomingTrackIDs
        } else if let savedCurrentIndex = snapshot.queueTrackIDs.firstIndex(
            of: snapshot.currentTrackID
        ) {
            fallbackTrackIDs =
                Array(snapshot.queueTrackIDs.dropFirst(savedCurrentIndex + 1))
                + Array(snapshot.queueTrackIDs.prefix(savedCurrentIndex))
        } else {
            fallbackTrackIDs = snapshot.queueTrackIDs
        }
        let restoredQueueTrackIDs = Set(restoredQueue.map(\.id))
        let fallbackTrack = fallbackTrackIDs.lazy.compactMap { trackID -> AudioTrack? in
            guard restoredQueueTrackIDs.contains(trackID) else {
                return nil
            }
            return tracksByID[trackID]
        }.first
        guard let restoredCurrentTrack = savedCurrentTrack ?? fallbackTrack ?? restoredQueue.first else {
            Self.playbackStateLogger.info(
                "Discarded saved playback state because its local files are unavailable"
            )
            playbackStateStore.clear()
            return false
        }

        let restoredElapsedTime =
            savedCurrentTrack == nil ? 0 : snapshot.elapsedTime

        isRestoringPlaybackState = true
        invalidateQueueUndo()
        queue = restoredQueue
        isShuffleEnabled = snapshot.isShuffleEnabled
        repeatMode = snapshot.repeatMode
        currentTrack = restoredCurrentTrack
        shuffledUpcoming = resolveTracks(snapshot.shuffledUpcomingTrackIDs).filter {
            $0.id != restoredCurrentTrack.id && restoredQueueTrackIDs.contains($0.id)
        }
        shuffleHistory = resolveTracks(snapshot.shuffleHistoryTrackIDs).filter {
            restoredQueueTrackIDs.contains($0.id)
        }
        playbackHistory = resolveTracks(snapshot.playbackHistoryTrackIDs)
        elapsedTime = restoredElapsedTime
        duration = 0
        errorMessage = nil
        isPlaying = false

        let item = AVPlayerItem(url: restoredCurrentTrack.localURL)
        invalidatePendingSeek()
        player.replaceCurrentItem(with: item)
        observePlayback(of: item, trackID: restoredCurrentTrack.id)
        if restoredElapsedTime > 0 {
            performSeek(to: restoredElapsedTime)
        }

        if snapshot.wasPlaying {
            do {
                try activateAudioSession()
                player.play()
                isPlaying = true
            } catch {
                errorMessage = error.localizedDescription
                player.pause()
                isPlaying = false
            }
        } else {
            player.pause()
            isPlaying = false
        }

        refreshObserversForPlaybackState()
        refreshPublishedQueue()
        updateRemoteCommandAvailability()
        updateNowPlayingInfo()
        isRestoringPlaybackState = false
        persistPlaybackState()
        return true
    }

    func checkpointPlaybackState() {
        persistPlaybackState(position: currentPlaybackPosition)
    }

    func play(_ track: AudioTrack, in availableTracks: [AudioTrack]) {
        invalidateQueueUndo()
        recordCurrentTrackInHistory(excluding: track)
        queue = availableTracks
        if !queue.contains(track) {
            queue.append(track)
        }
        shuffleHistory = []
        shuffledUpcoming = isShuffleEnabled ? shuffle(queue.filter { $0 != track }) : []
        startPlayback(track)
    }

    func playInOrder(_ tracks: [AudioTrack]) {
        guard let firstTrack = tracks.first else {
            return
        }
        if isShuffleEnabled {
            isShuffleEnabled = false
        }
        play(firstTrack, in: tracks)
    }

    func playShuffled(_ tracks: [AudioTrack]) {
        guard let firstTrack = shuffle(tracks).first else {
            return
        }
        if !isShuffleEnabled {
            isShuffleEnabled = true
        }
        play(firstTrack, in: tracks)
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
    }

    func cycleRepeatMode() {
        repeatMode = repeatMode.next
    }

    func addToEndOfQueue(_ track: AudioTrack) {
        guard let currentTrack else {
            play(track, in: [track])
            queueActionFeedback = QueueActionFeedback(
                message: "Playing “\(track.title)”",
                canUndo: false
            )
            return
        }
        guard track != currentTrack,
            let currentIndex = queue.firstIndex(of: currentTrack)
        else {
            return
        }

        let snapshot = makeQueueUndoSnapshot(currentTrackID: currentTrack.id)
        if isShuffleEnabled {
            queue.removeAll { $0 == track }
            queue.append(track)
            shuffledUpcoming.removeAll { $0 == track }
            shuffledUpcoming.append(track)
        } else {
            let currentFirstQueue =
                Array(queue[currentIndex...]) + Array(queue[..<currentIndex])
            queue = currentFirstQueue.filter { $0 != track }
            queue.append(track)
        }
        refreshPublishedQueue()
        updateRemoteCommandAvailability()
        publishQueueFeedback(
            message: "Added “\(track.title)” to the queue",
            snapshot: snapshot
        )
    }

    func playNext(_ track: AudioTrack) {
        guard let currentTrack else {
            play(track, in: [track])
            queueActionFeedback = QueueActionFeedback(
                message: "Playing “\(track.title)”",
                canUndo: false
            )
            return
        }
        guard track != currentTrack,
            let currentIndex = queue.firstIndex(of: currentTrack)
        else {
            return
        }

        let snapshot = makeQueueUndoSnapshot(currentTrackID: currentTrack.id)
        if isShuffleEnabled {
            queue.removeAll { $0 == track }
            queue.append(track)
            shuffledUpcoming.removeAll { $0 == track }
            shuffledUpcoming.insert(track, at: 0)
        } else {
            let currentFirstQueue =
                Array(queue[currentIndex...]) + Array(queue[..<currentIndex])
            queue = currentFirstQueue.filter { $0 != track }
            queue.insert(track, at: min(1, queue.endIndex))
        }
        refreshPublishedQueue()
        updateRemoteCommandAvailability()
        publishQueueFeedback(
            message: "Queued “\(track.title)” next",
            snapshot: snapshot
        )
    }

    func addToEndOfQueue(_ tracks: [AudioTrack], from collectionTitle: String) {
        enqueue(tracks, from: collectionTitle, placement: .end)
    }

    func playNext(_ tracks: [AudioTrack], from collectionTitle: String) {
        enqueue(tracks, from: collectionTitle, placement: .next)
    }

    func undoLastQueueAction() {
        guard let snapshot = queueUndoSnapshot,
            snapshot.currentTrackID == currentTrack?.id
        else {
            dismissQueueActionFeedback()
            return
        }
        queue = snapshot.queue
        shuffledUpcoming = snapshot.shuffledUpcoming
        refreshPublishedQueue()
        updateRemoteCommandAvailability()
        dismissQueueActionFeedback()
    }

    func dismissQueueActionFeedback(id: QueueActionFeedback.ID? = nil) {
        guard id == nil || id == queueActionFeedback?.id else {
            return
        }
        queueActionFeedback = nil
        queueUndoSnapshot = nil
    }

    func moveUpcomingTracks(fromOffsets sourceOffsets: IndexSet, toOffset destination: Int) {
        var upcoming = Array(playbackQueue.dropFirst())
        let validOffsets = IndexSet(sourceOffsets.filter { upcoming.indices.contains($0) })
        guard !validOffsets.isEmpty else {
            return
        }
        let movingTracks = validOffsets.map { upcoming[$0] }
        for index in validOffsets.sorted(by: >) {
            upcoming.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), upcoming.count)
        upcoming.insert(contentsOf: movingTracks, at: insertionIndex)
        replaceUpcomingQueue(with: upcoming)
    }

    func removeUpcomingTracks(atOffsets offsets: IndexSet) {
        var upcoming = Array(playbackQueue.dropFirst())
        let validOffsets = offsets.filter { upcoming.indices.contains($0) }
        guard !validOffsets.isEmpty else {
            return
        }
        for index in validOffsets.sorted(by: >) {
            upcoming.remove(at: index)
        }
        replaceUpcomingQueue(with: upcoming)
    }

    func removeUpcomingTrack(_ track: AudioTrack) {
        let upcoming = Array(playbackQueue.dropFirst())
        guard let index = upcoming.firstIndex(of: track) else {
            return
        }
        removeUpcomingTracks(atOffsets: IndexSet(integer: index))
    }

    func clearUpcomingQueue() {
        guard playbackQueue.count > 1 else {
            return
        }
        replaceUpcomingQueue(with: [])
    }

    func removeTrackFromPlayback(_ track: AudioTrack) {
        if currentTrack == track {
            stop()
        } else {
            invalidateQueueUndo()
            queue.removeAll { $0 == track }
            shuffledUpcoming.removeAll { $0 == track }
            shuffleHistory.removeAll { $0 == track }
            refreshPublishedQueue()
            updateRemoteCommandAvailability()
        }
        playbackHistory.removeAll { $0 == track }
        persistPlaybackState()
    }

    func playFromQueue(_ track: AudioTrack) {
        guard queue.contains(track), track != currentTrack else {
            return
        }
        invalidateQueueUndo()
        recordCurrentTrackInHistory(excluding: track)
        if isShuffleEnabled {
            if let currentTrack {
                shuffleHistory.append(currentTrack)
            }
            shuffledUpcoming.removeAll { $0 == track }
        }
        startPlayback(track)
    }

    private func startPlayback(_ track: AudioTrack) {
        do {
            guard FileManager.default.fileExists(atPath: track.localURL.path) else {
                throw PlaybackError.localFileUnavailable
            }
            try activateAudioSession()

            let item = AVPlayerItem(url: track.localURL)
            invalidatePendingSeek()
            player.replaceCurrentItem(with: item)
            observePlayback(of: item, trackID: track.id)
            currentTrack = track
            elapsedTime = 0
            duration = 0
            errorMessage = nil
            player.play()
            isPlaying = true
            refreshObserversForPlaybackState()
            refreshPublishedQueue()
            updateRemoteCommandAvailability()
            updateNowPlayingInfo()
        } catch {
            player.pause()
            errorMessage = error.localizedDescription
            isPlaying = false
            persistPlaybackState()
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player.pause()
        refreshPlaybackProgress()
        isPlaying = false
        updateNowPlayingInfo()
        stopPlaybackObservers()
        deactivateAudioSession()
        persistPlaybackState()
    }

    func resume() {
        guard currentTrack != nil else {
            return
        }
        do {
            try activateAudioSession()
            player.play()
            isPlaying = true
            errorMessage = nil
            updateNowPlayingInfo()
            refreshObserversForPlaybackState()
            persistPlaybackState()
        } catch {
            errorMessage = error.localizedDescription
            isPlaying = false
            stopPlaybackObservers()
            persistPlaybackState()
        }
    }

    func stop() {
        invalidateQueueUndo()
        player.pause()
        removePlaybackStateTimeObserver()
        invalidatePendingSeek()
        player.replaceCurrentItem(with: nil)
        clearItemObservers()
        currentTrack = nil
        isPlaying = false
        elapsedTime = 0
        duration = 0
        queue = []
        playbackQueue = []
        shuffledUpcoming = []
        shuffleHistory = []
        errorMessage = nil
        resources.nowPlayingArtworkTrackID = nil
        resources.nowPlayingArtwork = nil
        resources.nowPlayingArtworkProvider = nil
        resources.artworkLoadTask?.cancel()
        resources.artworkLoadTask = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteCommandAvailability()
        playbackStateStore?.clear()
        stopPlaybackObservers()
        deactivateAudioSession()
    }

    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite else {
            return
        }
        let clampedSeconds = min(max(seconds, 0), max(duration, 0))
        performSeek(to: clampedSeconds)
    }

    func playNext() {
        guard let currentTrack, !queue.isEmpty else {
            return
        }

        invalidateQueueUndo()

        if isShuffleEnabled {
            guard queue.count > 1 else {
                return
            }
            if shuffledUpcoming.isEmpty {
                guard repeatMode != .off else {
                    return
                }
                shuffledUpcoming = shuffle(queue.filter { $0 != currentTrack })
            }
            guard !shuffledUpcoming.isEmpty else {
                return
            }
            shuffleHistory.append(currentTrack)
            recordCurrentTrackInHistory()
            startPlayback(shuffledUpcoming.removeFirst())
            return
        }

        guard let currentIndex = queue.firstIndex(of: currentTrack) else {
            return
        }
        let nextIndex = queue.index(after: currentIndex)
        guard nextIndex != queue.endIndex || repeatMode != .off else {
            return
        }
        recordCurrentTrackInHistory()
        startPlayback(queue[nextIndex == queue.endIndex ? queue.startIndex : nextIndex])
    }

    func playPrevious() {
        if elapsedTime > 3 {
            seek(to: 0)
            return
        }
        guard let currentTrack, !queue.isEmpty else {
            return
        }

        invalidateQueueUndo()

        if isShuffleEnabled {
            guard let previousTrack = shuffleHistory.popLast() else {
                seek(to: 0)
                return
            }
            shuffledUpcoming.removeAll { $0 == previousTrack }
            shuffledUpcoming.insert(currentTrack, at: 0)
            startPlayback(previousTrack)
            return
        }

        guard let currentIndex = queue.firstIndex(of: currentTrack) else {
            return
        }
        if currentIndex == queue.startIndex, repeatMode == .off {
            seek(to: 0)
            return
        }
        let previousIndex =
            currentIndex == queue.startIndex
            ? queue.index(before: queue.endIndex)
            : queue.index(before: currentIndex)
        startPlayback(queue[previousIndex])
    }

    private func resetShuffleState() {
        shuffleHistory = []
        guard isShuffleEnabled, let currentTrack else {
            shuffledUpcoming = []
            return
        }
        shuffledUpcoming = shuffle(queue.filter { $0 != currentTrack })
    }

    private func enqueue(
        _ tracks: [AudioTrack],
        from collectionTitle: String,
        placement: CollectionQueuePlacement
    ) {
        var seenTracks = Set<AudioTrack>()
        let uniqueTracks = tracks.filter { seenTracks.insert($0).inserted }
        guard let firstTrack = uniqueTracks.first else {
            return
        }
        guard let currentTrack, let currentIndex = queue.firstIndex(of: currentTrack) else {
            play(firstTrack, in: uniqueTracks)
            queueActionFeedback = QueueActionFeedback(
                message:
                    "Playing \(uniqueTracks.count) \(trackCountLabel(uniqueTracks.count)) from “\(collectionTitle)”",
                canUndo: false
            )
            return
        }

        let incomingTracks = uniqueTracks.filter { $0 != currentTrack }
        guard !incomingTracks.isEmpty else {
            return
        }
        let incomingSet = Set(incomingTracks)
        let snapshot = makeQueueUndoSnapshot(currentTrackID: currentTrack.id)

        if isShuffleEnabled {
            queue.removeAll { incomingSet.contains($0) }
            queue.append(contentsOf: incomingTracks)
            shuffledUpcoming.removeAll { incomingSet.contains($0) }
            switch placement {
            case .next:
                shuffledUpcoming.insert(contentsOf: incomingTracks, at: 0)
            case .end:
                shuffledUpcoming.append(contentsOf: incomingTracks)
            }
        } else {
            let currentFirstQueue =
                Array(queue[currentIndex...]) + Array(queue[..<currentIndex])
            let remainingTracks = currentFirstQueue.dropFirst().filter {
                !incomingSet.contains($0)
            }
            switch placement {
            case .next:
                queue = [currentTrack] + incomingTracks + remainingTracks
            case .end:
                queue = [currentTrack] + remainingTracks + incomingTracks
            }
        }

        refreshPublishedQueue()
        updateRemoteCommandAvailability()
        let count = incomingTracks.count
        let message: String
        switch placement {
        case .next:
            message = "Queued \(count) \(trackCountLabel(count)) from “\(collectionTitle)” next"
        case .end:
            message = "Added \(count) \(trackCountLabel(count)) from “\(collectionTitle)” to the queue"
        }
        publishQueueFeedback(message: message, snapshot: snapshot)
    }

    private func trackCountLabel(_ count: Int) -> String {
        count == 1 ? "track" : "tracks"
    }

    private func makeQueueUndoSnapshot(currentTrackID: AudioTrack.ID) -> QueueUndoSnapshot {
        QueueUndoSnapshot(
            currentTrackID: currentTrackID,
            queue: queue,
            shuffledUpcoming: shuffledUpcoming
        )
    }

    private func publishQueueFeedback(message: String, snapshot: QueueUndoSnapshot) {
        queueUndoSnapshot = snapshot
        queueActionFeedback = QueueActionFeedback(message: message, canUndo: true)
    }

    private func invalidateQueueUndo() {
        queueUndoSnapshot = nil
        queueActionFeedback = nil
    }

    private func replaceUpcomingQueue(with upcoming: [AudioTrack]) {
        guard let currentTrack else {
            queue = upcoming
            playbackQueue = upcoming
            return
        }
        invalidateQueueUndo()
        queue = [currentTrack] + upcoming.filter { $0 != currentTrack }
        if isShuffleEnabled {
            shuffledUpcoming = upcoming.filter { $0 != currentTrack }
        }
        refreshPublishedQueue()
        updateRemoteCommandAvailability()
    }

    private func recordCurrentTrackInHistory(excluding track: AudioTrack? = nil) {
        guard let currentTrack, currentTrack != track else {
            return
        }
        playbackHistory.removeAll { $0 == currentTrack }
        playbackHistory.append(currentTrack)
        if playbackHistory.count > 50 {
            playbackHistory.removeFirst(playbackHistory.count - 50)
        }
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        if !resources.isAudioSessionConfigured {
            // A music player is long-form audio. Without this policy the route picker can
            // connect to an AirPlay receiver, but iOS does not treat this session as an
            // AirPlay media route on every receiver.
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio
            )
            resources.isAudioSessionConfigured = true
        }
        if !resources.isAudioSessionActive {
            try session.setActive(true)
            resources.isAudioSessionActive = true
        }
    }

    private func deactivateAudioSession() {
        guard resources.isAudioSessionActive else {
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            resources.isAudioSessionActive = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginProgressUpdates() {
        resources.progressObserverClients += 1
        guard resources.progressObserverClients == 1,
            resources.areProgressUpdatesEnabled
        else {
            return
        }
        refreshPlaybackProgress()
        if isPlaying {
            installTimeObserver()
        }
    }

    func endProgressUpdates() {
        resources.progressObserverClients = max(resources.progressObserverClients - 1, 0)
        guard resources.progressObserverClients == 0,
            let timeObserver = resources.timeObserver
        else {
            return
        }
        player.removeTimeObserver(timeObserver)
        resources.timeObserver = nil
    }

    func setProgressUpdatesEnabled(_ enabled: Bool) {
        guard resources.areProgressUpdatesEnabled != enabled else {
            return
        }
        resources.areProgressUpdatesEnabled = enabled

        guard enabled else {
            stopProgressTimeObserver()
            return
        }
        guard resources.progressObserverClients > 0, isPlaying else {
            return
        }
        refreshPlaybackProgress()
        installTimeObserver()
    }

    private func stopProgressTimeObserver() {
        guard let timeObserver = resources.timeObserver else {
            return
        }
        player.removeTimeObserver(timeObserver)
        resources.timeObserver = nil
    }

    private func installTimeObserver() {
        guard resources.timeObserver == nil else {
            return
        }
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        resources.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPlaybackProgress()
            }
        }
    }

    private func installPlaybackStateTimeObserver() {
        guard playbackStateStore != nil,
            resources.playbackStateTimeObserver == nil
        else {
            return
        }
        let interval = CMTime(seconds: 10, preferredTimescale: 600)
        resources.playbackStateTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkpointPlaybackState()
            }
        }
    }

    private func refreshObserversForPlaybackState() {
        if isPlaying {
            installPlaybackStateTimeObserver()
            if resources.progressObserverClients > 0,
                resources.areProgressUpdatesEnabled
            {
                installTimeObserver()
            }
            return
        }
        removePlaybackStateTimeObserver()
        stopProgressTimeObserver()
    }

    private func stopPlaybackObservers() {
        removePlaybackStateTimeObserver()
        stopProgressTimeObserver()
    }

    private func removePlaybackStateTimeObserver() {
        guard let playbackStateTimeObserver = resources.playbackStateTimeObserver else {
            return
        }
        player.removeTimeObserver(playbackStateTimeObserver)
        resources.playbackStateTimeObserver = nil
    }

    private func refreshPlaybackProgress() {
        guard pendingSeekPosition == nil else {
            return
        }
        let seconds = player.currentTime().seconds
        if seconds.isFinite {
            elapsedTime = max(seconds, 0)
        }
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        resources.notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleAudioInterruption(type: rawType, options: rawOptions)
                }
            }
        )
        resources.notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(reason: rawReason)
                }
            }
        )
    }

    private func observePlayback(of item: AVPlayerItem, trackID: AudioTrack.ID) {
        clearItemObservers()
        let center = NotificationCenter.default

        resources.playbackEndObserver = center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentTrack?.id == trackID else {
                    return
                }
                if self.repeatMode == .one {
                    self.restartCurrentTrack()
                } else if self.canPlayNext {
                    self.playNext()
                } else if self.repeatMode == .all, self.queue.count == 1 {
                    self.restartCurrentTrack()
                } else {
                    self.seek(to: 0)
                    self.pause()
                }
            }
        }

        resources.playbackFailureObserver = center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let message =
                (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                as? Error)?.localizedDescription ?? "The audio data could not be decoded."
            Task { @MainActor [weak self] in
                self?.handlePlaybackFailure(message, trackID: trackID)
            }
        }

        resources.itemStatusObservation = item.observe(\.status, options: [.new]) {
            [weak self] item, _ in
            guard item.status == .failed else {
                return
            }
            let message =
                item.error?.localizedDescription
                ?? "The audio item could not be loaded."
            Task { @MainActor [weak self] in
                self?.handlePlaybackFailure(message, trackID: trackID)
            }
        }
        resources.itemDurationObservation = item.observe(\.duration, options: [.initial, .new]) {
            [weak self] item, _ in
            let seconds = item.duration.seconds
            guard seconds.isFinite, seconds > 0 else {
                return
            }
            Task { @MainActor [weak self] in
                guard let self, self.currentTrack?.id == trackID,
                    abs(self.duration - seconds) > 0.01
                else {
                    return
                }
                self.duration = seconds
                self.updateNowPlayingInfo()
            }
        }
    }

    private func clearItemObservers() {
        let center = NotificationCenter.default
        if let playbackEndObserver = resources.playbackEndObserver {
            center.removeObserver(playbackEndObserver)
            resources.playbackEndObserver = nil
        }
        if let playbackFailureObserver = resources.playbackFailureObserver {
            center.removeObserver(playbackFailureObserver)
            resources.playbackFailureObserver = nil
        }
        resources.itemStatusObservation = nil
        resources.itemDurationObservation = nil
    }

    private func handlePlaybackFailure(_ message: String, trackID: AudioTrack.ID) {
        guard currentTrack?.id == trackID else {
            return
        }
        player.pause()
        isPlaying = false
        errorMessage = PlaybackError.itemFailed(message).localizedDescription
        updateNowPlayingInfo()
        persistPlaybackState()
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        resources.remoteTargets.append(
            (
                center.playCommand,
                center.playCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in self?.resume() }
                    return .success
                }
            )
        )
        resources.remoteTargets.append(
            (
                center.pauseCommand,
                center.pauseCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in self?.pause() }
                    return .success
                }
            )
        )
        resources.remoteTargets.append(
            (
                center.togglePlayPauseCommand,
                center.togglePlayPauseCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in self?.togglePlayPause() }
                    return .success
                }
            )
        )
        resources.remoteTargets.append(
            (
                center.nextTrackCommand,
                center.nextTrackCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in self?.playNext() }
                    return .success
                }
            )
        )
        resources.remoteTargets.append(
            (
                center.previousTrackCommand,
                center.previousTrackCommand.addTarget { [weak self] _ in
                    Task { @MainActor [weak self] in self?.playPrevious() }
                    return .success
                }
            )
        )
        resources.remoteTargets.append(
            (
                center.changePlaybackPositionCommand,
                center.changePlaybackPositionCommand.addTarget { [weak self] event in
                    guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                        return .commandFailed
                    }
                    Task { @MainActor [weak self] in
                        self?.seek(to: positionEvent.positionTime)
                    }
                    return .success
                }
            )
        )
        updateRemoteCommandAvailability()
    }

    private func updateRemoteCommandAvailability() {
        let center = MPRemoteCommandCenter.shared()
        let hasTrack = currentTrack != nil
        center.playCommand.isEnabled = hasTrack
        center.pauseCommand.isEnabled = hasTrack
        center.togglePlayPauseCommand.isEnabled = hasTrack
        center.nextTrackCommand.isEnabled = hasTrack && canPlayNext
        center.previousTrackCommand.isEnabled = hasTrack
        center.changePlaybackPositionCommand.isEnabled = hasTrack
    }

    private func updateNowPlayingInfo() {
        guard let currentTrack else {
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTrack.title,
            MPMediaItemPropertyAlbumTitle: currentTrack.albumDisplayTitle,
            MPMediaItemPropertyArtist: currentTrack.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if resources.nowPlayingArtworkTrackID != currentTrack.id {
            resources.nowPlayingArtworkTrackID = currentTrack.id
            resources.nowPlayingArtworkProvider = nil
            resources.nowPlayingArtwork = nil
            resources.artworkLoadTask?.cancel()
            resources.artworkLoadTask = nil
            if let artworkURL = currentTrack.artworkURL {
                let trackID = currentTrack.id
                resources.artworkLoadTask = Task { @MainActor [weak self] in
                    guard
                        let image = await ArtworkImageCache.image(
                            at: artworkURL,
                            maxPixelSize: 1_024
                        ), !Task.isCancelled, let self,
                        self.currentTrack?.id == trackID
                    else {
                        return
                    }
                    let provider = NowPlayingArtworkProvider(image: image)
                    self.resources.nowPlayingArtworkProvider = provider
                    self.resources.nowPlayingArtwork = MPMediaItemArtwork(
                        boundsSize: image.size,
                        requestHandler: provider.image(for:)
                    )
                    self.updateNowPlayingInfo()
                }
            }
        }
        if let artwork = resources.nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func handleAudioInterruption(type rawType: UInt?, options rawOptions: UInt?) {
        guard let rawType,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return
        }
        switch type {
        case .began:
            refreshPlaybackProgress()
            isPlaying = false
            stopPlaybackObservers()
            deactivateAudioSession()
            updateNowPlayingInfo()
            persistPlaybackState()
        case .ended:
            if AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0).contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason rawReason: UInt?) {
        guard let rawReason,
            AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
        else {
            return
        }
        pause()
    }

    private func refreshPublishedQueue() {
        defer { persistPlaybackState() }
        guard let currentTrack, let currentIndex = queue.firstIndex(of: currentTrack) else {
            playbackQueue = queue
            return
        }
        if isShuffleEnabled {
            playbackQueue = [currentTrack] + shuffledUpcoming
            return
        }
        if repeatMode == .off {
            playbackQueue = Array(queue[currentIndex...])
        } else {
            playbackQueue = Array(queue[currentIndex...]) + Array(queue[..<currentIndex])
        }
    }

    private var currentPlaybackPosition: TimeInterval {
        if let pendingSeekPosition {
            return pendingSeekPosition
        }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else {
            return max(elapsedTime, 0)
        }
        return max(seconds, 0)
    }

    private func performSeek(to seconds: TimeInterval) {
        let seekID = UUID()
        pendingSeekID = seekID
        pendingSeekPosition = seconds
        elapsedTime = seconds
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pendingSeekID == seekID else {
                    return
                }
                self.pendingSeekID = nil
                self.pendingSeekPosition = nil
                self.refreshPlaybackProgress()
                self.updateNowPlayingInfo()
                self.persistPlaybackState()
            }
        }
        updateNowPlayingInfo()
        persistPlaybackState()
    }

    private func invalidatePendingSeek() {
        pendingSeekID = nil
        pendingSeekPosition = nil
    }

    private func persistPlaybackState(position: TimeInterval? = nil) {
        guard !isRestoringPlaybackState,
            let playbackStateStore,
            let currentTrack
        else {
            return
        }

        var persistedQueue = queue
        if !persistedQueue.contains(where: { $0.id == currentTrack.id }) {
            persistedQueue.insert(currentTrack, at: 0)
        }
        let savedPosition = position ?? elapsedTime
        let snapshot = PlaybackStateSnapshot(
            queueTrackIDs: persistedQueue.map(\.id),
            currentTrackID: currentTrack.id,
            shuffledUpcomingTrackIDs: shuffledUpcoming.map(\.id),
            shuffleHistoryTrackIDs: shuffleHistory.map(\.id),
            playbackHistoryTrackIDs: playbackHistory.map(\.id),
            elapsedTime: savedPosition.isFinite ? max(savedPosition, 0) : 0,
            wasPlaying: isPlaying,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode
        )
        do {
            try playbackStateStore.save(snapshot)
        } catch {
            Self.playbackStateLogger.error(
                "Could not save playback state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private var canPlayNext: Bool {
        guard let currentTrack, queue.count > 1 else {
            return false
        }
        if isShuffleEnabled {
            return !shuffledUpcoming.isEmpty || repeatMode != .off
        }
        guard let currentIndex = queue.firstIndex(of: currentTrack) else {
            return false
        }
        return queue.index(after: currentIndex) != queue.endIndex || repeatMode != .off
    }

    private func restartCurrentTrack() {
        seek(to: 0)
        resume()
    }
}

#if DEBUG
    extension AudioPlayer {
        static func preview(
            track: AudioTrack = .previewImported,
            isPlaying: Bool = true,
            elapsedTime: TimeInterval = 42,
            duration: TimeInterval = 218
        ) -> AudioPlayer {
            let player = AudioPlayer()
            player.currentTrack = track
            player.isPlaying = isPlaying
            player.elapsedTime = elapsedTime
            player.duration = duration
            player.queue = [track]
            return player
        }
    }
#endif
