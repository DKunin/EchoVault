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
            referenceID: track.playlistReferenceID,
            title: track.title,
            subtitle: track.artist
        )
    }

    static func folder(_ folder: MusicFolder) -> PlaylistItemDraft {
        PlaylistItemDraft(
            kind: .folder,
            referenceID: folder.playlistReferenceID,
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
            for referenceID in track.playlistReferenceIDs {
                tracksByID[referenceID] = track
            }
        }
        var foldersByID: [MusicFolder.ID: MusicFolder] = [:]
        for folder in availableFolders {
            for referenceID in folder.playlistReferenceIDs {
                foldersByID[referenceID] = folder
            }
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

    func portableForExport(
        availableTracks: [AudioTrack],
        availableFolders: [MusicFolder]
    ) -> MusicPlaylist {
        let tracksByReferenceID = Self.tracksByReferenceID(availableTracks)
        let foldersByReferenceID = Self.foldersByReferenceID(availableFolders)
        let portableItems = items.map { item in
            let referenceID: String
            switch item.kind {
            case .track:
                referenceID =
                    tracksByReferenceID[item.referenceID]?.playlistReferenceID
                    ?? item.referenceID
            case .folder:
                referenceID =
                    foldersByReferenceID[item.referenceID]?.playlistReferenceID
                    ?? item.referenceID
            }
            return PlaylistItem(
                id: item.id,
                draft: PlaylistItemDraft(
                    kind: item.kind,
                    referenceID: referenceID,
                    title: item.title,
                    subtitle: item.subtitle
                )
            )
        }
        return MusicPlaylist(
            id: id,
            name: name,
            items: portableItems,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func unavailableItemCount(
        availableTracks: [AudioTrack],
        availableFolders: [MusicFolder]
    ) -> Int {
        let tracksByReferenceID = Self.tracksByReferenceID(availableTracks)
        let foldersByReferenceID = Self.foldersByReferenceID(availableFolders)
        return items.lazy.filter { item in
            switch item.kind {
            case .track:
                return tracksByReferenceID[item.referenceID] == nil
            case .folder:
                return foldersByReferenceID[item.referenceID] == nil
            }
        }.count
    }

    private static func tracksByReferenceID(_ tracks: [AudioTrack]) -> [String: AudioTrack] {
        var result: [String: AudioTrack] = [:]
        for track in tracks {
            for referenceID in track.playlistReferenceIDs {
                result[referenceID] = track
            }
        }
        return result
    }

    private static func foldersByReferenceID(_ folders: [MusicFolder]) -> [String: MusicFolder] {
        var result: [String: MusicFolder] = [:]
        for folder in folders {
            for referenceID in folder.playlistReferenceIDs {
                result[referenceID] = folder
            }
        }
        return result
    }
}

extension AudioTrack {
    var playlistReferenceID: String {
        guard let remoteURL else {
            return id
        }
        return "webdav-track:\(remoteURL.absoluteString)"
    }

    var playlistReferenceIDs: [String] {
        guard let remoteURL else {
            return [id]
        }
        return [id, remoteURL.absoluteString, playlistReferenceID]
    }

    func matchesPlaylistReferenceID(_ referenceID: String) -> Bool {
        playlistReferenceIDs.contains(referenceID)
    }
}

extension MusicFolder {
    var playlistReferenceID: String {
        guard let remoteDirectoryURL else {
            return id
        }
        return "webdav-folder:\(remoteDirectoryURL.absoluteString)"
    }

    var playlistReferenceIDs: [String] {
        guard let remoteDirectoryURL else {
            return [id]
        }
        return [id, remoteDirectoryURL.absoluteString, playlistReferenceID]
    }

    func matchesPlaylistReferenceID(_ referenceID: String) -> Bool {
        playlistReferenceIDs.contains(referenceID)
    }

    private var remoteDirectoryURL: URL? {
        tracks.lazy.compactMap(\.remoteURL).first?.deletingLastPathComponent()
    }
}
