import Foundation

enum PlaylistItemKind: String, Codable, Sendable {
    case track
    case folder
}

struct PlaylistItemDraft: Hashable, Sendable {
    let kind: PlaylistItemKind
    let referenceID: String
    let title: String
    let subtitle: String?

    static func track(_ track: AudioTrack) -> PlaylistItemDraft {
        PlaylistItemDraft(
            kind: .track,
            referenceID: track.id,
            title: track.title,
            subtitle: track.artist
        )
    }

    static func folder(_ folder: MusicFolder) -> PlaylistItemDraft {
        PlaylistItemDraft(
            kind: .folder,
            referenceID: folder.id,
            title: folder.title,
            subtitle: folder.path
        )
    }
}

struct PlaylistItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: PlaylistItemKind
    let referenceID: String
    let title: String
    let subtitle: String?

    init(id: UUID = UUID(), draft: PlaylistItemDraft) {
        self.id = id
        kind = draft.kind
        referenceID = draft.referenceID
        title = draft.title
        subtitle = draft.subtitle
    }
}

struct MusicPlaylist: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var items: [PlaylistItem]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        items: [PlaylistItem] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func resolvedTracks(
        availableTracks: [AudioTrack],
        availableFolders: [MusicFolder]
    ) -> [AudioTrack] {
        var tracksByID: [AudioTrack.ID: AudioTrack] = [:]
        for track in availableTracks {
            tracksByID[track.id] = track
        }
        var foldersByID: [MusicFolder.ID: MusicFolder] = [:]
        for folder in availableFolders {
            foldersByID[folder.id] = folder
        }
        var resolvedTrackIDs = Set<AudioTrack.ID>()
        var result: [AudioTrack] = []

        for item in items {
            let candidates: [AudioTrack]
            switch item.kind {
            case .track:
                candidates = tracksByID[item.referenceID].map { [$0] } ?? []
            case .folder:
                candidates = foldersByID[item.referenceID]?.tracks ?? []
            }
            for track in candidates where resolvedTrackIDs.insert(track.id).inserted {
                result.append(track)
            }
        }
        return result
    }
}
