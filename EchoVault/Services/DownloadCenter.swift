import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class DownloadCenter {
    enum DownloadError: LocalizedError {
        case alreadyDownloading
        case noAudioFiles

        var errorDescription: String? {
            switch self {
            case .alreadyDownloading:
                return "One or more tracks are already downloading."
            case .noAudioFiles:
                return "No supported audio files were found in this folder."
            }
        }
    }

    struct FolderProgress: Equatable, Sendable {
        let completed: Int
        let total: Int
    }

    enum FolderStatus: Equatable, Sendable {
        case discovering
        case downloading(FolderProgress)
    }

    private(set) var activeURLs: Set<URL> = []
    private(set) var folderStatuses: [URL: FolderStatus] = [:]
    @ObservationIgnored private let library: MusicLibrary
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.example.EchoVault",
        category: "DownloadCenter"
    )

    init(library: MusicLibrary) {
        self.library = library
    }

    func isDownloading(_ item: WebDAVItem) -> Bool {
        activeURLs.contains(item.url)
    }

    func folderStatus(at directoryURL: URL) -> FolderStatus? {
        folderStatuses[directoryURL]
    }

    func cache(
        _ item: WebDAVItem,
        using configuration: WebDAVConfiguration
    ) async throws -> AudioTrack {
        if let existing = library.cachedTrack(matching: item) {
            return existing
        }
        guard activeURLs.insert(item.url).inserted else {
            throw DownloadError.alreadyDownloading
        }
        defer { activeURLs.remove(item.url) }

        let temporaryURL = try await WebDAVClient(configuration: configuration).download(item)
        defer {
            do {
                try FileManager.default.removeItem(at: temporaryURL)
            } catch {
                logger.error("Temporary download cleanup failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        try Task.checkCancellation()
        return try await library.addDownloadedFile(at: temporaryURL, item: item)
    }

    func cacheFolder(
        at directoryURL: URL,
        using configuration: WebDAVConfiguration,
        progress: (FolderProgress) -> Void
    ) async throws -> [AudioTrack] {
        guard folderStatuses[directoryURL] == nil else {
            throw DownloadError.alreadyDownloading
        }
        folderStatuses[directoryURL] = .discovering
        defer { folderStatuses[directoryURL] = nil }

        let client = WebDAVClient(configuration: configuration)
        let items = try await client.listAudioFilesRecursively(at: directoryURL)
        guard !items.isEmpty else {
            throw DownloadError.noAudioFiles
        }

        var cachedByURL: [URL: AudioTrack] = [:]
        var missingItems: [WebDAVItem] = []
        for item in items {
            if let track = library.cachedTrack(matching: item) {
                cachedByURL[item.url] = track
            } else {
                missingItems.append(item)
            }
        }

        let missingURLs = Set(missingItems.map(\.url))
        guard activeURLs.isDisjoint(with: missingURLs) else {
            throw DownloadError.alreadyDownloading
        }
        activeURLs.formUnion(missingURLs)
        defer { activeURLs.subtract(missingURLs) }

        var completed = cachedByURL.count
        let initialProgress = FolderProgress(completed: completed, total: items.count)
        folderStatuses[directoryURL] = .downloading(initialProgress)
        progress(initialProgress)
        var downloads: [DownloadedWebDAVFile] = []
        defer {
            for download in downloads {
                do {
                    try FileManager.default.removeItem(at: download.temporaryURL)
                } catch {
                    logger.error(
                        "Temporary folder download cleanup failed: \(error.localizedDescription, privacy: .private)"
                    )
                }
            }
        }

        do {
            for item in missingItems {
                try Task.checkCancellation()
                let temporaryURL = try await client.download(item)
                downloads.append(
                    DownloadedWebDAVFile(temporaryURL: temporaryURL, item: item)
                )
                completed += 1
                let currentProgress = FolderProgress(completed: completed, total: items.count)
                folderStatuses[directoryURL] = .downloading(currentProgress)
                progress(currentProgress)
            }
        } catch {
            if !downloads.isEmpty {
                _ = try? await library.addDownloadedFiles(downloads)
            }
            throw error
        }

        if !downloads.isEmpty {
            for track in try await library.addDownloadedFiles(downloads) {
                if let remoteURL = track.remoteURL {
                    cachedByURL[remoteURL] = track
                }
            }
        }

        return items.compactMap { item in
            cachedByURL[item.url] ?? library.cachedTrack(matching: item)
        }
    }
}
