import SwiftUI
import UIKit

enum EchoVaultTheme {
    static let background = Color.black
    static let separator = Color.white.opacity(0.14)
    static let horizontalContentPadding: CGFloat = 16
}

extension View {
    func echoVaultBlackSurface() -> some View {
        scrollContentBackground(.hidden)
            .background(EchoVaultTheme.background)
    }
}

@main
struct EchoVaultApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var library: MusicLibrary
    @State private var player: AudioPlayer
    @State private var playlistStore: PlaylistStore
    @State private var webDAVSettings: WebDAVSettings
    @State private var downloadCenter: DownloadCenter

    init() {
        Self.configureAppearance()
        let library = MusicLibrary()
        _library = State(initialValue: library)
        _player = State(
            initialValue: AudioPlayer(playbackStateStore: PlaybackStateStore())
        )
        _playlistStore = State(initialValue: PlaylistStore())
        _webDAVSettings = State(initialValue: WebDAVSettings())
        _downloadCenter = State(initialValue: DownloadCenter(library: library))
    }

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environment(library)
                .environment(player)
                .environment(playlistStore)
                .environment(webDAVSettings)
                .environment(downloadCenter)
                .preferredColorScheme(.dark)
                .background(EchoVaultTheme.background.ignoresSafeArea())
                .task {
                    await library.refresh()
                    guard library.errorMessage == nil else {
                        return
                    }
                    player.restorePlaybackState(from: library.tracks)
                }
                .onChange(of: scenePhase, initial: true) { _, newPhase in
                    player.setProgressUpdatesEnabled(newPhase == .active)
                    guard newPhase != .active else {
                        return
                    }
                    player.checkpointPlaybackState()
                }
        }
    }

    private static func configureAppearance() {
        let navigationBarAppearance = UINavigationBarAppearance()
        navigationBarAppearance.configureWithOpaqueBackground()
        navigationBarAppearance.backgroundColor = .black
        navigationBarAppearance.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = navigationBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationBarAppearance
        UINavigationBar.appearance().compactAppearance = navigationBarAppearance

        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = .black
        tabBarAppearance.shadowColor = .clear
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

        UITableView.appearance().backgroundColor = .black
        UICollectionView.appearance().backgroundColor = .black
    }
}
