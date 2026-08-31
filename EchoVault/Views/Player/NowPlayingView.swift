import AVKit
import MediaPlayer
import SwiftUI

struct NowPlayingLayoutMetrics: Equatable {
    static let compactHeightBreakpoint: CGFloat = 790

    let isCompactHeight: Bool
    let horizontalPadding: CGFloat
    let verticalSpacing: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let artworkSize: CGFloat
    let artworkCornerRadius: CGFloat
    let artworkSymbolSize: CGFloat
    let artworkShadowRadius: CGFloat
    let artworkShadowOffset: CGFloat
    let detailSpacing: CGFloat
    let timelineSpacing: CGFloat
    let controlSpacing: CGFloat
    let playButtonSize: CGFloat

    init(availableSize: CGSize) {
        isCompactHeight = availableSize.height < Self.compactHeightBreakpoint
        horizontalPadding = isCompactHeight ? 24 : 28
        verticalSpacing = isCompactHeight ? 16 : 24
        topPadding = isCompactHeight ? 8 : 16
        bottomPadding = isCompactHeight ? 12 : 24
        artworkCornerRadius = isCompactHeight ? 26 : 32
        artworkSymbolSize = isCompactHeight ? 74 : 88
        artworkShadowRadius = isCompactHeight ? 18 : 24
        artworkShadowOffset = isCompactHeight ? 8 : 12
        detailSpacing = isCompactHeight ? 4 : 6
        timelineSpacing = isCompactHeight ? 4 : 6
        controlSpacing = isCompactHeight ? 8 : 12
        playButtonSize = isCompactHeight ? 64 : 72

        let widthAvailableForArtwork = max(
            availableSize.width - (horizontalPadding * 2),
            0
        )
        artworkSize = min(widthAvailableForArtwork, isCompactHeight ? 300 : 380)
    }
}

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioPlayer.self) private var player
    @Environment(MusicLibrary.self) private var library
    @AppStorage("interface.hapticsEnabled") private var hapticsEnabled = true
    @State private var scrubbedTime: TimeInterval?
    @State private var selectionFeedbackTrigger = 0
    @State private var playbackFeedbackTrigger = 0
    @Namespace private var albumTransition

    var body: some View {
        NavigationStack {
            ZStack {
                EchoVaultTheme.background.ignoresSafeArea()

                GeometryReader { proxy in
                    let layout = NowPlayingLayoutMetrics(availableSize: proxy.size)

                    ScrollView {
                        playerContent(using: layout)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .background(EchoVaultTheme.background)
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        PlaybackQueueView()
                    } label: {
                        Label("Queue", systemImage: "list.bullet")
                    }
                    .disabled(player.playbackQueue.isEmpty)
                    .accessibilityIdentifier("player.queue")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let track = player.currentTrack {
                        Button {
                            library.toggleFavourite(track)
                        } label: {
                            Label(
                                library.isFavourite(track)
                                    ? "Remove from Favourites"
                                    : "Add to Favourites",
                                systemImage: library.isFavourite(track)
                                    ? "heart.fill"
                                    : "heart"
                            )
                        }
                        .accessibilityIdentifier("now-playing.favourite")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .background(EchoVaultTheme.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationBackground(EchoVaultTheme.background)
        .onAppear {
            player.beginProgressUpdates()
        }
        .onDisappear {
            player.endProgressUpdates()
        }
        .sensoryFeedback(trigger: selectionFeedbackTrigger) {
            hapticsEnabled ? .selection : nil
        }
        .sensoryFeedback(trigger: playbackFeedbackTrigger) {
            hapticsEnabled ? .impact(weight: .light) : nil
        }
    }

    private func playerContent(using layout: NowPlayingLayoutMetrics) -> some View {
        VStack(spacing: layout.verticalSpacing) {
            artwork(using: layout)
                .frame(width: layout.artworkSize, height: layout.artworkSize)
                .padding(.top, layout.topPadding)

            trackDetails(isCompact: layout.isCompactHeight, spacing: layout.detailSpacing)
            timeline(spacing: layout.timelineSpacing)
            controls(
                spacing: layout.controlSpacing,
                playButtonSize: layout.playButtonSize
            )
            outputControls

            if let errorMessage = player.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, layout.bottomPadding)
        .frame(maxWidth: .infinity)
        .background(EchoVaultTheme.background)
    }

    @ViewBuilder
    private func artwork(using layout: NowPlayingLayoutMetrics) -> some View {
        if #available(iOS 18.0, *), let album = currentAlbum {
            artworkImage(using: layout)
                .matchedTransitionSource(
                    id: albumTransitionID(album),
                    in: albumTransition
                )
        } else {
            artworkImage(using: layout)
        }
    }

    private func artworkImage(using layout: NowPlayingLayoutMetrics) -> some View {
        TrackArtworkView(
            artworkURL: player.currentTrack?.artworkURL,
            cornerRadius: layout.artworkCornerRadius,
            symbolSize: layout.artworkSymbolSize,
            maxPixelSize: 1_024
        )
        .background(EchoVaultTheme.background)
        .shadow(
            color: Color.black.opacity(0.24),
            radius: layout.artworkShadowRadius,
            y: layout.artworkShadowOffset
        )
    }

    private func trackDetails(isCompact: Bool, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            Text(player.currentTrack?.title ?? "Nothing playing")
                .font(isCompact ? .title3.bold() : .title2.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let track = player.currentTrack {
                NavigationLink {
                    artistDestination(for: track)
                } label: {
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows tracks by this artist")

                if let album = currentAlbum {
                    NavigationLink {
                        albumDestination(album)
                    } label: {
                        Label(album.title, systemImage: "square.stack")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this album")
                } else {
                    Text(track.albumDisplayTitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Choose a track from your library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func timeline(spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            Slider(
                value: Binding(
                    get: {
                        min(
                            scrubbedTime ?? player.elapsedTime,
                            max(player.duration, 1)
                        )
                    },
                    set: { newValue in
                        scrubbedTime = newValue
                    }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { isEditing in
                    guard !isEditing, let scrubbedTime else {
                        return
                    }
                    player.seek(to: scrubbedTime)
                    self.scrubbedTime = nil
                }
            )
            .disabled(player.duration <= 0)
            .accessibilityLabel("Playback position")

            HStack {
                Text(formatTime(scrubbedTime ?? player.elapsedTime))
                Spacer()
                Text("-\(formatTime(max(player.duration - (scrubbedTime ?? player.elapsedTime), 0)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func controls(spacing: CGFloat, playButtonSize: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button {
                performSelectionFeedback(player.toggleShuffle)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(player.isShuffleEnabled ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffleEnabled ? "On" : "Off")

            Button {
                performSelectionFeedback(player.playPrevious)
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous track")

            Button {
                player.togglePlayPause()
                playbackFeedbackTrigger += 1
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: playButtonSize))
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                performSelectionFeedback(player.playNext)
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next track")

            Button {
                performSelectionFeedback(player.cycleRepeatMode)
            } label: {
                Image(systemName: player.repeatMode.systemImage)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(
                        player.repeatMode == .off ? Color.secondary : Color.accentColor
                    )
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode.accessibilityValue)
            .accessibilityHint("Cycles between repeat off, all tracks, and one track")
        }
        .foregroundStyle(.primary)
        .disabled(player.currentTrack == nil)
    }

    private var outputControls: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            SystemVolumeSlider()
                .frame(maxWidth: .infinity, minHeight: 44)

            AudioRoutePicker()
                .frame(width: 44, height: 44)
        }
        .accessibilityElement(children: .contain)
    }

    private var currentAlbum: MusicAlbum? {
        guard let track = player.currentTrack else {
            return nil
        }
        return library.albums.first { $0.id == track.albumGroupingKey }
    }

    private func artistDestination(for track: AudioTrack) -> some View {
        LibraryCollectionDetailView(
            kind: "Artist",
            title: track.artist,
            subtitle: "Artist",
            artworkURL: track.artworkURL,
            tracks: library.tracks.filter { $0.artist == track.artist }
        )
    }

    @ViewBuilder
    private func albumDestination(_ album: MusicAlbum) -> some View {
        if #available(iOS 18.0, *) {
            LibraryCollectionDetailView(
                kind: "Album",
                title: album.title,
                subtitle: album.artist,
                artworkURL: album.artworkURL,
                tracks: album.tracks
            )
            .navigationTransition(
                .zoom(sourceID: albumTransitionID(album), in: albumTransition)
            )
        } else {
            LibraryCollectionDetailView(
                kind: "Album",
                title: album.title,
                subtitle: album.artist,
                artworkURL: album.artworkURL,
                tracks: album.tracks
            )
        }
    }

    private func albumTransitionID(_ album: MusicAlbum) -> String {
        "now-playing-album:\(album.id)"
    }

    private func performSelectionFeedback(_ action: () -> Void) {
        action()
        selectionFeedbackTrigger += 1
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else {
            return "0:00"
        }
        let totalSeconds = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private final class SystemVolumeContainerView: UIView {
    let volumeView = MPVolumeView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        volumeView.showsVolumeSlider = true
        // The route-button property is deprecated in favor of AVRoutePickerView, which is
        // rendered separately below. KVC targets that public Objective-C property while
        // keeping this view limited to the only public system-volume slider on iOS.
        volumeView.setValue(false, forKey: "showsRouteButton")
        volumeView.accessibilityLabel = "System volume"
        volumeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(volumeView)
        NSLayoutConstraint.activate([
            volumeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            volumeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            volumeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            volumeView.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}

private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context _: Context) -> SystemVolumeContainerView {
        SystemVolumeContainerView()
    }

    func updateUIView(_ view: SystemVolumeContainerView, context _: Context) {
        view.volumeView.tintColor = .label
    }
}

private struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context _: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.prioritizesVideoDevices = false
        routePicker.tintColor = .secondaryLabel
        routePicker.activeTintColor = .systemBlue
        routePicker.accessibilityLabel = "Audio output"
        return routePicker
    }

    func updateUIView(_ view: AVRoutePickerView, context _: Context) {
        view.tintColor = .secondaryLabel
        view.activeTintColor = .systemBlue
    }
}

struct PlaybackQueueView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioPlayer.self) private var player
    @State private var isConfirmingClear = false

    let isPresentedAsSheet: Bool

    init(isPresentedAsSheet: Bool = false) {
        self.isPresentedAsSheet = isPresentedAsSheet
    }

    var body: some View {
        Group {
            if let currentTrack = player.currentTrack {
                List {
                    Section("Now Playing") {
                        Button(action: player.togglePlayPause) {
                            QueueTrackRow(
                                track: currentTrack,
                                trailingSystemImage: player.isPlaying
                                    ? "speaker.wave.2.fill"
                                    : "pause.fill",
                                trailingColor: Color.accentColor
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(player.isPlaying ? "Pause" : "Resume") \(currentTrack.title) by \(currentTrack.artist)"
                        )
                    }
                    .listRowBackground(EchoVaultTheme.background)

                    if !upcomingTracks.isEmpty {
                        Section {
                            ForEach(upcomingTracks) { track in
                                upcomingTrackRow(track)
                            }
                            .onDelete(perform: player.removeUpcomingTracks)
                            .onMove(perform: player.moveUpcomingTracks)

                            Button(role: .destructive) {
                                isConfirmingClear = true
                            } label: {
                                Label("Clear Up Next", systemImage: "text.badge.minus")
                            }
                        } header: {
                            Text("Up Next")
                        } footer: {
                            Text(
                                "Swipe left or use More to remove a track. Use Edit to reorder."
                            )
                        }
                        .listRowBackground(EchoVaultTheme.background)
                    }

                    if !player.playbackHistory.isEmpty {
                        Section("Recently Played") {
                            ForEach(recentlyPlayed) { track in
                                QueueTrackRow(
                                    track: track,
                                    trailingSystemImage: "clock.arrow.circlepath",
                                    trailingColor: .secondary
                                )
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .listRowBackground(EchoVaultTheme.background)
                    }
                }
                .listStyle(.insetGrouped)
                .echoVaultBlackSurface()
            } else {
                ContentUnavailableView(
                    "Queue is empty",
                    systemImage: "text.line.last.and.arrowtriangle.forward",
                    description: Text("Play a track or add music from Library or WebDAV.")
                )
            }
        }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isPresentedAsSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            if !upcomingTracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .confirmationDialog(
            "Clear all upcoming tracks?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Up Next", role: .destructive) {
                player.clearUpcomingQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current track will keep playing.")
        }
    }

    private var upcomingTracks: [AudioTrack] {
        Array(player.playbackQueue.dropFirst())
    }

    private func upcomingTrackRow(_ track: AudioTrack) -> some View {
        HStack(spacing: 0) {
            Button {
                player.playFromQueue(track)
            } label: {
                QueueTrackRow(track: track)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title) by \(track.artist)")

            QueueRemovalActionsMenu(trackTitle: track.title) {
                player.removeUpcomingTrack(track)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                player.removeUpcomingTrack(track)
            } label: {
                Label("Remove", systemImage: "text.badge.minus")
            }
            .accessibilityLabel("Remove \(track.title) from queue")
            .accessibilityIdentifier("queue.track.remove.swipe")
        }
        .contextMenu {
            Button(role: .destructive) {
                player.removeUpcomingTrack(track)
            } label: {
                Label("Remove from Queue", systemImage: "text.badge.minus")
            }
            .accessibilityIdentifier("queue.track.remove.context")
        }
    }

    private var recentlyPlayed: [AudioTrack] {
        Array(player.playbackHistory.reversed().prefix(20))
    }
}

private struct QueueTrackRow: View {
    let track: AudioTrack
    var trailingSystemImage: String?
    var trailingColor: Color = .secondary

    var body: some View {
        HStack(spacing: 12) {
            TrackArtworkView(
                artworkURL: track.artworkURL,
                cornerRadius: 8,
                symbolSize: 17
            )
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .foregroundStyle(trailingColor)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct QueueRemovalActionsMenu: View {
    let trackTitle: String
    let remove: () -> Void

    var body: some View {
        Menu {
            Button(role: .destructive, action: remove) {
                Label("Remove from Queue", systemImage: "text.badge.minus")
            }
            .accessibilityIdentifier("queue.track.remove")
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions for \(trackTitle)")
        .accessibilityIdentifier("queue.track.actions")
    }
}

#if DEBUG
    #Preview("Now playing") {
        NowPlayingView()
            .environment(AudioPlayer.preview(track: .previewCached))
            .environment(MusicLibrary.preview(tracks: [.previewCached]))
    }
#endif
