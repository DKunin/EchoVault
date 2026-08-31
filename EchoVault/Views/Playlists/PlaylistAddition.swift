import SwiftUI

struct PlaylistAdditionRequest: Identifiable, Hashable {
    let id = UUID()
    let drafts: [PlaylistItemDraft]
    let sourceTitle: String
}

struct PresentPlaylistAdditionAction: Sendable {
    private let action: @MainActor @Sendable ([PlaylistItemDraft], String) -> Void

    init(action: @escaping @MainActor @Sendable ([PlaylistItemDraft], String) -> Void) {
        self.action = action
    }

    @MainActor
    func callAsFunction(_ drafts: [PlaylistItemDraft], sourceTitle: String) {
        action(drafts, sourceTitle)
    }
}

private struct PresentPlaylistAdditionActionKey: EnvironmentKey {
    static let defaultValue = PresentPlaylistAdditionAction { _, _ in }
}

extension EnvironmentValues {
    var presentPlaylistAddition: PresentPlaylistAdditionAction {
        get { self[PresentPlaylistAdditionActionKey.self] }
        set { self[PresentPlaylistAdditionActionKey.self] = newValue }
    }
}

struct PlaylistPickerView: View {
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(\.dismiss) private var dismiss

    let request: PlaylistAdditionRequest
    @State private var creationRequest: PlaylistCreationRequest?
    @State private var alert: UserFacingAlert?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: createPlaylist) {
                        Label("New Playlist", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("playlist.picker.create")
                }

                Section("Choose a Playlist") {
                    if playlistStore.playlists.isEmpty {
                        Text("Create a playlist to add \(request.sourceTitle).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(playlistStore.playlists) { playlist in
                            Button {
                                add(to: playlist.id)
                            } label: {
                                PlaylistSelectionRow(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("playlist.picker.\(playlist.id.uuidString)")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .echoVaultBlackSurface()
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
        }
        .sheet(item: $creationRequest) { request in
            CreatePlaylistView(request: request) {
                dismiss()
            }
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(EchoVaultTheme.background)
        .accessibilityIdentifier("playlist.picker")
    }

    private func createPlaylist() {
        creationRequest = PlaylistCreationRequest(initialDrafts: request.drafts)
    }

    private func add(to playlistID: MusicPlaylist.ID) {
        do {
            let addedCount = try playlistStore.add(request.drafts, to: playlistID)
            guard addedCount > 0 else {
                alert = UserFacingAlert(
                    title: "Already in playlist",
                    message: "\(request.sourceTitle) is already included in this playlist."
                )
                return
            }
            dismiss()
        } catch {
            alert = UserFacingAlert(
                title: "Could not update playlist",
                message: error.localizedDescription
            )
        }
    }
}

struct PlaylistCreationRequest: Identifiable {
    let id = UUID()
    let initialDrafts: [PlaylistItemDraft]

    init(initialDrafts: [PlaylistItemDraft] = []) {
        self.initialDrafts = initialDrafts
    }
}

struct CreatePlaylistView: View {
    @Environment(PlaylistStore.self) private var playlistStore
    @Environment(\.dismiss) private var dismiss

    let request: PlaylistCreationRequest
    let onCreated: () -> Void
    @State private var name = ""
    @State private var alert: UserFacingAlert?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Playlist name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(create)
                        .accessibilityIdentifier("playlist.create.name")
                }
            }
            .echoVaultBlackSurface()
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("playlist.create.confirm")
                }
            }
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .presentationDetents([.medium])
        .presentationBackground(EchoVaultTheme.background)
    }

    private func create() {
        do {
            let playlistID = try playlistStore.createPlaylist(named: name)
            if !request.initialDrafts.isEmpty {
                _ = try playlistStore.add(request.initialDrafts, to: playlistID)
            }
            onCreated()
            dismiss()
        } catch {
            alert = UserFacingAlert(
                title: "Could not create playlist",
                message: error.localizedDescription
            )
        }
    }
}

private struct PlaylistSelectionRow: View {
    let playlist: MusicPlaylist

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(playlist.items.count) \(playlist.items.count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            Image(systemName: "plus.circle")
                .foregroundStyle(Color.accentColor)
        }
        .contentShape(Rectangle())
    }
}
