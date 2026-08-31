import Foundation

enum TrackOrigin: String, Codable, Sendable {
    case imported
    case webDAV

    var label: String {
        switch self {
        case .imported:
            return "On this device"
        case .webDAV:
            return "WebDAV download"
        }
    }
}

struct AudioTrack: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let albumTitle: String?
    let folderName: String?
    let folderIdentifier: String?
    let filename: String
    let localURL: URL
    let artworkURL: URL?
    let origin: TrackOrigin
    let remoteURL: URL?
    let downloadedAt: Date?

    init(
        title: String,
        artist: String = "Unknown Artist",
        albumTitle: String? = nil,
        folderName: String? = nil,
        folderIdentifier: String? = nil,
        filename: String,
        localURL: URL,
        artworkURL: URL? = nil,
        origin: TrackOrigin,
        remoteURL: URL? = nil,
        downloadedAt: Date? = nil
    ) {
        self.id = localURL.standardizedFileURL.path
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.folderName = folderName
        self.folderIdentifier = folderIdentifier
        self.filename = filename
        self.localURL = localURL
        self.artworkURL = artworkURL
        self.origin = origin
        self.remoteURL = remoteURL
        self.downloadedAt = downloadedAt
    }

    var albumDisplayTitle: String {
        albumTitle ?? folderName ?? "Unknown Album"
    }

    var albumGroupingKey: String {
        if let albumTitle {
            return "metadata:\(albumTitle.foldingForSearch)"
        }
        if let folderName {
            return "folder:\((folderIdentifier ?? folderName).foldingForSearch)"
        }
        return "unknown"
    }
}

struct MusicAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let tracks: [AudioTrack]
    let artworkURL: URL?

    init(groupingKey: String, tracks: [AudioTrack]) {
        let sortedTracks = tracks.sorted {
            if $0.artist != $1.artist {
                return $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let artists = Set(
            sortedTracks.map(\.artist).filter { $0 != "Unknown Artist" }
        )

        self.id = groupingKey
        self.title = sortedTracks.first?.albumDisplayTitle ?? "Unknown Album"
        if artists.count == 1 {
            self.artist = artists.first ?? "Unknown Artist"
        } else if artists.isEmpty {
            self.artist = "Unknown Artist"
        } else {
            self.artist = "Various Artists"
        }
        self.tracks = sortedTracks
        self.artworkURL = sortedTracks.compactMap(\.artworkURL).first
    }
}

struct MusicFolder: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let path: String?
    let tracks: [AudioTrack]
    let artworkURL: URL?

    init(groupingKey: String, tracks: [AudioTrack]) {
        let sortedTracks = tracks.sorted {
            let artistComparison = $0.artist.localizedStandardCompare($1.artist)
            if artistComparison != .orderedSame {
                return artistComparison == .orderedAscending
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        id = groupingKey
        title = sortedTracks.first?.folderName ?? "Unfiled"
        path = Self.displayPath(for: sortedTracks.first?.folderIdentifier)
        self.tracks = sortedTracks
        artworkURL = sortedTracks.compactMap(\.artworkURL).first
    }

    private static func displayPath(for identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else {
            return nil
        }
        if let url = URL(string: identifier), url.scheme != nil {
            return url.path.removingPercentEncoding
        }
        return identifier
    }
}

enum AudioFileSupport {
    static let supportedExtensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "m4b", "mp3", "mp4", "wav",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func displayTitle(for filename: String) -> String {
        let title =
            URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .removingPercentEncoding ?? filename
        return title.isEmpty ? filename : title
    }
}

private extension String {
    var foldingForSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

#if DEBUG
    extension AudioTrack {
        static let previewImported = AudioTrack(
            title: "Northern Lights",
            artist: "Aurora Lane",
            albumTitle: "Night Drive",
            filename: "Northern Lights.m4a",
            localURL: URL(fileURLWithPath: "/tmp/Northern Lights.m4a"),
            origin: .imported
        )

        static let previewCached = AudioTrack(
            title: "Midnight Signals",
            artist: "Signal Coast",
            albumTitle: "After Hours",
            filename: "Midnight Signals.mp3",
            localURL: URL(fileURLWithPath: "/tmp/Midnight Signals.mp3"),
            origin: .webDAV,
            remoteURL: URL(string: "https://example.com/music/Midnight%20Signals.mp3"),
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
#endif
