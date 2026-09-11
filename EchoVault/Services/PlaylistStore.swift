import Foundation
import Observation

enum PlaylistStoreError: LocalizedError, Equatable {
    case emptyName
    case duplicateName
    case playlistNotFound

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a playlist name."
        case .duplicateName:
            "A playlist with this name already exists."
        case .playlistNotFound:
            "This playlist is no longer available."
        }
    }
}

private struct PlaylistStoreSnapshot: Codable {
    static let currentVersion = 1

    let version: Int
    let playlists: [MusicPlaylist]
}

@MainActor
@Observable
final class PlaylistStore {
    private(set) var playlists: [MusicPlaylist]
    private(set) var errorMessage: String?

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let now: () -> Date

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "playlists.snapshot",
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.now = now

        guard let data = userDefaults.data(forKey: storageKey) else {
            playlists = []
            errorMessage = nil
            return
        }
        do {
            let snapshot = try JSONDecoder().decode(PlaylistStoreSnapshot.self, from: data)
            guard snapshot.version == PlaylistStoreSnapshot.currentVersion else {
                playlists = []
                errorMessage = "Saved playlists use an unsupported format."
                return
            }
            playlists = snapshot.playlists
            errorMessage = nil
        } catch {
            playlists = []
            errorMessage = "Saved playlists could not be loaded."
        }
    }

    func playlist(id: MusicPlaylist.ID) -> MusicPlaylist? {
        playlists.first { $0.id == id }
    }

    @discardableResult
    func createPlaylist(named proposedName: String) throws -> MusicPlaylist.ID {
        let name = try validatedName(proposedName)
        let timestamp = now()
        let playlist = MusicPlaylist(name: name, createdAt: timestamp, updatedAt: timestamp)
        var updatedPlaylists = playlists
        updatedPlaylists.append(playlist)
        try save(updatedPlaylists)
        return playlist.id
    }

    func deletePlaylist(id: MusicPlaylist.ID) throws {
        var updatedPlaylists = playlists
        guard let index = updatedPlaylists.firstIndex(where: { $0.id == id }) else {
            throw PlaylistStoreError.playlistNotFound
        }
        updatedPlaylists.remove(at: index)
        try save(updatedPlaylists)
    }

    @discardableResult
    func importPlaylist(_ importedPlaylist: MusicPlaylist) throws -> MusicPlaylist.ID {
        let name = try availableImportedName(for: importedPlaylist.name)
        let timestamp = now()
        var references = Set<PlaylistItemReference>()
        let items = importedPlaylist.items.compactMap { item -> PlaylistItem? in
            let reference = PlaylistItemReference(
                kind: item.kind,
                referenceID: item.referenceID
            )
            guard references.insert(reference).inserted else {
                return nil
            }
            return PlaylistItem(
                draft: PlaylistItemDraft(
                    kind: item.kind,
                    referenceID: item.referenceID,
                    title: item.title,
                    subtitle: item.subtitle
                )
            )
        }
        let playlist = MusicPlaylist(
            name: name,
            items: items,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var updatedPlaylists = playlists
        updatedPlaylists.append(playlist)
        try save(updatedPlaylists)
        return playlist.id
    }

    @discardableResult
    func add(_ drafts: [PlaylistItemDraft], to playlistID: MusicPlaylist.ID) throws -> Int {
        var updatedPlaylists = playlists
        guard let playlistIndex = updatedPlaylists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistStoreError.playlistNotFound
        }

        var existingReferences = Set(
            updatedPlaylists[playlistIndex].items.map {
                PlaylistItemReference(kind: $0.kind, referenceID: $0.referenceID)
            }
        )
        var newItems: [PlaylistItem] = []
        for draft in drafts {
            let reference = PlaylistItemReference(kind: draft.kind, referenceID: draft.referenceID)
            guard existingReferences.insert(reference).inserted else {
                continue
            }
            newItems.append(PlaylistItem(draft: draft))
        }
        guard !newItems.isEmpty else {
            return 0
        }

        updatedPlaylists[playlistIndex].items.append(contentsOf: newItems)
        updatedPlaylists[playlistIndex].updatedAt = now()
        try save(updatedPlaylists)
        return newItems.count
    }

    func removeItems(at offsets: IndexSet, from playlistID: MusicPlaylist.ID) throws {
        var updatedPlaylists = playlists
        guard let playlistIndex = updatedPlaylists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistStoreError.playlistNotFound
        }
        let validOffsets = offsets.filter(updatedPlaylists[playlistIndex].items.indices.contains)
        guard !validOffsets.isEmpty else {
            return
        }
        for index in validOffsets.sorted(by: >) {
            updatedPlaylists[playlistIndex].items.remove(at: index)
        }
        updatedPlaylists[playlistIndex].updatedAt = now()
        try save(updatedPlaylists)
    }

    func removeItem(id itemID: PlaylistItem.ID, from playlistID: MusicPlaylist.ID) throws {
        guard let playlist = playlist(id: playlistID),
            let index = playlist.items.firstIndex(where: { $0.id == itemID })
        else {
            throw PlaylistStoreError.playlistNotFound
        }
        try removeItems(at: IndexSet(integer: index), from: playlistID)
    }

    func moveItems(
        from source: IndexSet,
        to destination: Int,
        in playlistID: MusicPlaylist.ID
    ) throws {
        var updatedPlaylists = playlists
        guard let playlistIndex = updatedPlaylists.firstIndex(where: { $0.id == playlistID }) else {
            throw PlaylistStoreError.playlistNotFound
        }
        let originalItems = updatedPlaylists[playlistIndex].items
        let validSource = source.filter(originalItems.indices.contains).sorted()
        guard !validSource.isEmpty else {
            return
        }
        let movedItems = validSource.map { originalItems[$0] }
        var remainingItems = originalItems
        for index in validSource.reversed() {
            remainingItems.remove(at: index)
        }
        let removedBeforeDestination = validSource.lazy.filter { $0 < destination }.count
        let insertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            remainingItems.count
        )
        remainingItems.insert(contentsOf: movedItems, at: insertionIndex)
        updatedPlaylists[playlistIndex].items = remainingItems
        updatedPlaylists[playlistIndex].updatedAt = now()
        try save(updatedPlaylists)
    }

    private func validatedName(_ proposedName: String) throws -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw PlaylistStoreError.emptyName
        }
        guard
            !playlists.contains(where: {
                $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                    == .orderedSame
            })
        else {
            throw PlaylistStoreError.duplicateName
        }
        return name
    }

    private func availableImportedName(for proposedName: String) throws -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw PlaylistStoreError.emptyName
        }
        guard containsPlaylist(named: name) else {
            return name
        }

        var copyNumber = 1
        while true {
            let suffix = copyNumber == 1 ? "Imported" : "Imported \(copyNumber)"
            let candidate = "\(name) (\(suffix))"
            if !containsPlaylist(named: candidate) {
                return candidate
            }
            copyNumber += 1
        }
    }

    private func containsPlaylist(named name: String) -> Bool {
        playlists.contains {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
                == .orderedSame
        }
    }

    private func save(_ updatedPlaylists: [MusicPlaylist]) throws {
        let snapshot = PlaylistStoreSnapshot(
            version: PlaylistStoreSnapshot.currentVersion,
            playlists: updatedPlaylists
        )
        let data = try JSONEncoder().encode(snapshot)
        userDefaults.set(data, forKey: storageKey)
        playlists = updatedPlaylists
        errorMessage = nil
    }
}

private struct PlaylistItemReference: Hashable {
    let kind: PlaylistItemKind
    let referenceID: String
}
