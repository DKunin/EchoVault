import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let echoVaultPlaylist = UTType(
        exportedAs: "com.dkunin.echovault.playlist",
        conformingTo: .json
    )
}

enum PlaylistDocumentError: LocalizedError, Equatable {
    case invalidFile
    case fileTooLarge
    case unsupportedVersion(Int)
    case invalidPlaylist

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "This is not a valid EchoVault playlist file."
        case .fileTooLarge:
            return "This playlist file is too large to import."
        case .unsupportedVersion(let version):
            return "Playlist format version \(version) is not supported."
        case .invalidPlaylist:
            return "This playlist contains invalid or excessive data."
        }
    }
}

struct PlaylistDocument: FileDocument {
    static let maximumFileSize = 5 * 1_024 * 1_024
    static let maximumItemCount = 10_000
    static var readableContentTypes: [UTType] { [.echoVaultPlaylist] }

    let playlist: MusicPlaylist

    init(
        playlist: MusicPlaylist,
        availableTracks: [AudioTrack],
        availableFolders: [MusicFolder]
    ) {
        self.playlist = playlist.portableForExport(
            availableTracks: availableTracks,
            availableFolders: availableFolders
        )
    }

    init(data: Data) throws {
        guard !data.isEmpty else {
            throw PlaylistDocumentError.invalidFile
        }
        guard data.count <= Self.maximumFileSize else {
            throw PlaylistDocumentError.fileTooLarge
        }

        let payload: PlaylistFilePayload
        do {
            payload = try JSONDecoder().decode(PlaylistFilePayload.self, from: data)
        } catch {
            throw PlaylistDocumentError.invalidFile
        }
        guard payload.format == PlaylistFilePayload.formatIdentifier else {
            throw PlaylistDocumentError.invalidFile
        }
        guard payload.version == PlaylistFilePayload.currentVersion else {
            throw PlaylistDocumentError.unsupportedVersion(payload.version)
        }
        try Self.validate(payload.playlist)
        playlist = payload.playlist
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw PlaylistDocumentError.invalidFile
        }
        try self.init(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try encodedData())
    }

    func encodedData() throws -> Data {
        try Self.validate(playlist)
        let payload = PlaylistFilePayload(
            format: PlaylistFilePayload.formatIdentifier,
            version: PlaylistFilePayload.currentVersion,
            playlist: playlist
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= Self.maximumFileSize else {
            throw PlaylistDocumentError.fileTooLarge
        }
        return data
    }

    static func defaultFilename(for playlist: MusicPlaylist) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = playlist.name.components(separatedBy: invalidCharacters)
        let filename = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? "Playlist" : String(filename.prefix(120))
    }

    private static func validate(_ playlist: MusicPlaylist) throws {
        let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
            name.count <= 255,
            playlist.items.count <= maximumItemCount
        else {
            throw PlaylistDocumentError.invalidPlaylist
        }

        for item in playlist.items {
            guard !item.referenceID.isEmpty,
                item.referenceID.count <= 4_096,
                !item.title.isEmpty,
                item.title.count <= 1_024,
                (item.subtitle?.count ?? 0) <= 1_024
            else {
                throw PlaylistDocumentError.invalidPlaylist
            }
        }
    }
}

private struct PlaylistFilePayload: Codable, Sendable {
    static let formatIdentifier = "com.dkunin.echovault.playlist"
    static let currentVersion = 1

    let format: String
    let version: Int
    let playlist: MusicPlaylist
}
