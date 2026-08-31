import SwiftUI

struct TrackQueueActionsMenu: View {
    let trackTitle: String
    let isFavourite: Bool
    let playNext: () -> Void
    let addToEnd: () -> Void
    let addToPlaylist: () -> Void
    let toggleFavourite: () -> Void
    let deleteFromDevice: (() -> Void)?

    init(
        trackTitle: String,
        isFavourite: Bool,
        playNext: @escaping () -> Void,
        addToEnd: @escaping () -> Void,
        addToPlaylist: @escaping () -> Void,
        toggleFavourite: @escaping () -> Void,
        deleteFromDevice: (() -> Void)? = nil
    ) {
        self.trackTitle = trackTitle
        self.isFavourite = isFavourite
        self.playNext = playNext
        self.addToEnd = addToEnd
        self.addToPlaylist = addToPlaylist
        self.toggleFavourite = toggleFavourite
        self.deleteFromDevice = deleteFromDevice
    }

    var body: some View {
        Menu {
            queueActionButtons
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions for \(trackTitle)")
    }

    @ViewBuilder
    private var queueActionButtons: some View {
        Button(action: playNext) {
            Label("Play Next", systemImage: "text.insert")
        }
        .accessibilityIdentifier("track.queue.next")

        Button(action: addToEnd) {
            Label("Add to End of Queue", systemImage: "text.badge.plus")
        }
        .accessibilityIdentifier("track.queue.append")

        Button(action: addToPlaylist) {
            Label("Add to Playlist", systemImage: "music.note.list")
        }
        .accessibilityIdentifier("track.playlist.add")

        Button(action: toggleFavourite) {
            Label(
                isFavourite ? "Remove from Favourites" : "Add to Favourites",
                systemImage: isFavourite ? "heart.slash" : "heart"
            )
        }
        .accessibilityIdentifier("track.favourite")

        if let deleteFromDevice {
            Divider()
            Button(role: .destructive, action: deleteFromDevice) {
                Label("Delete from Device", systemImage: "trash")
            }
            .accessibilityIdentifier("track.delete.local")
        }
    }
}

extension View {
    func queueActionsContextMenu(
        isFavourite: Bool,
        playNext: @escaping () -> Void,
        addToEnd: @escaping () -> Void,
        addToPlaylist: @escaping () -> Void,
        toggleFavourite: @escaping () -> Void,
        deleteFromDevice: (() -> Void)? = nil
    ) -> some View {
        contextMenu {
            Button(action: playNext) {
                Label("Play Next", systemImage: "text.insert")
            }
            .accessibilityIdentifier("track.queue.next")

            Button(action: addToEnd) {
                Label("Add to End of Queue", systemImage: "text.badge.plus")
            }
            .accessibilityIdentifier("track.queue.append")

            Button(action: addToPlaylist) {
                Label("Add to Playlist", systemImage: "music.note.list")
            }
            .accessibilityIdentifier("track.playlist.add")

            Button(action: toggleFavourite) {
                Label(
                    isFavourite ? "Remove from Favourites" : "Add to Favourites",
                    systemImage: isFavourite ? "heart.slash" : "heart"
                )
            }
            .accessibilityIdentifier("track.favourite")

            if let deleteFromDevice {
                Divider()
                Button(role: .destructive, action: deleteFromDevice) {
                    Label("Delete from Device", systemImage: "trash")
                }
                .accessibilityIdentifier("track.delete.local")
            }
        }
    }
}
