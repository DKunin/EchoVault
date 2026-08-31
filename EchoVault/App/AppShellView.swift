import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case library
    case playlists
    case webDAV
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .library:
            return "Library"
        case .playlists:
            return "Playlists"
        case .webDAV:
            return "WebDAV"
        case .settings:
            return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library:
            return "music.note.list"
        case .playlists:
            return "rectangle.stack.badge.play"
        case .webDAV:
            return "externaldrive.connected.to.line.below"
        case .settings:
            return "gearshape"
        }
    }
}

private enum AppSheet: Identifiable {
    case nowPlaying
    case queue
    case addToPlaylist(PlaylistAdditionRequest)

    var id: String {
        switch self {
        case .nowPlaying:
            "now-playing"
        case .queue:
            "queue"
        case .addToPlaylist(let request):
            "add-to-playlist-\(request.id.uuidString)"
        }
    }
}

struct AppShellView: View {
    @Environment(AudioPlayer.self) private var player
    @Environment(WebDAVSettings.self) private var webDAVSettings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedTab: AppTab = .library
    @State private var presentedSheet: AppSheet?
    @State private var webDAVPath: [WebDAVLocation] = []

    var body: some View {
        adaptiveTabView
            .environment(
                \.presentPlaylistAddition,
                PresentPlaylistAdditionAction { drafts, sourceTitle in
                    presentedSheet = .addToPlaylist(
                        PlaylistAdditionRequest(drafts: drafts, sourceTitle: sourceTitle)
                    )
                }
            )
            .background(EchoVaultTheme.background.ignoresSafeArea())
            .toolbarBackground(EchoVaultTheme.background, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .overlay(alignment: .bottom) {
                if let feedback = player.queueActionFeedback {
                    QueueActionBanner(
                        feedback: feedback,
                        undo: player.undoLastQueueAction,
                        openQueue: {
                            player.dismissQueueActionFeedback()
                            presentedSheet = .queue
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, queueBannerBottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
                }
            }
            .animation(.snappy, value: player.queueActionFeedback)
            .task(id: player.queueActionFeedback?.id) {
                guard let feedback = player.queueActionFeedback else {
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(6))
                } catch {
                    return
                }
                player.dismissQueueActionFeedback(id: feedback.id)
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .nowPlaying:
                    NowPlayingView()
                case .queue:
                    NavigationStack {
                        PlaybackQueueView(isPresentedAsSheet: true)
                    }
                case .addToPlaylist(let request):
                    PlaylistPickerView(request: request)
                }
            }
            .onChange(of: webDAVSettings.revision) {
                webDAVPath.removeAll()
            }
    }

    private var queueBannerBottomPadding: CGFloat {
        guard player.currentTrack != nil else {
            return 72
        }
        return dynamicTypeSize.isAccessibilitySize ? 156 : 120
    }

    @ViewBuilder
    private var adaptiveTabView: some View {
        if #available(iOS 26.1, *) {
            tabs(includeLegacyMiniPlayer: false)
                .tabBarMinimizeBehavior(.onScrollDown)
                .tabViewBottomAccessory(isEnabled: player.currentTrack != nil) {
                    NativeMiniPlayerAccessory {
                        presentedSheet = .nowPlaying
                    }
                }
        } else if #available(iOS 26.0, *) {
            if player.currentTrack != nil {
                tabs(includeLegacyMiniPlayer: false)
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .tabViewBottomAccessory {
                        NativeMiniPlayerAccessory {
                            presentedSheet = .nowPlaying
                        }
                    }
            } else {
                tabs(includeLegacyMiniPlayer: false)
                    .tabBarMinimizeBehavior(.onScrollDown)
            }
        } else {
            tabs(includeLegacyMiniPlayer: true)
        }
    }

    private func tabs(includeLegacyMiniPlayer: Bool) -> some View {
        TabView(selection: $selectedTab) {
            tabContent(includeLegacyMiniPlayer: includeLegacyMiniPlayer) {
                NavigationStack {
                    LibraryView()
                }
            }
            .tabItem {
                Label(AppTab.library.title, systemImage: AppTab.library.systemImage)
            }
            .tag(AppTab.library)

            tabContent(includeLegacyMiniPlayer: includeLegacyMiniPlayer) {
                NavigationStack {
                    PlaylistsView()
                }
            }
            .tabItem {
                Label(AppTab.playlists.title, systemImage: AppTab.playlists.systemImage)
            }
            .tag(AppTab.playlists)

            tabContent(includeLegacyMiniPlayer: includeLegacyMiniPlayer) {
                NavigationStack(path: $webDAVPath) {
                    WebDAVRootView()
                }
            }
            .tabItem {
                Label(AppTab.webDAV.title, systemImage: AppTab.webDAV.systemImage)
            }
            .tag(AppTab.webDAV)

            tabContent(includeLegacyMiniPlayer: includeLegacyMiniPlayer) {
                NavigationStack {
                    SettingsView()
                }
            }
            .tabItem {
                Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage)
            }
            .tag(AppTab.settings)
        }
    }

    private func tabContent<Content: View>(
        includeLegacyMiniPlayer: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .background(EchoVaultTheme.background)
            .toolbarBackground(EchoVaultTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if includeLegacyMiniPlayer, player.currentTrack != nil {
                    MiniPlayerView(presentation: .legacy) {
                        presentedSheet = .nowPlaying
                    }
                }
            }
    }
}

private struct QueueActionBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let feedback: QueueActionFeedback
    let undo: () -> Void
    let openQueue: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    message
                    actions
                }
            } else {
                HStack(spacing: 12) {
                    message
                    Spacer(minLength: 4)
                    actions
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(EchoVaultTheme.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
    }

    private var message: some View {
        Label(feedback.message, systemImage: "text.badge.checkmark")
            .font(.subheadline.weight(.semibold))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if feedback.canUndo {
                Button("Undo", action: undo)
                    .frame(minWidth: 44, minHeight: 44)
            }
            Button("Open", action: openQueue)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
    }
}

@available(iOS 26.0, *)
private struct NativeMiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    let showNowPlaying: () -> Void

    var body: some View {
        MiniPlayerView(
            presentation: placement == .inline ? .accessoryInline : .accessoryExpanded,
            showNowPlaying: showNowPlaying
        )
    }
}
