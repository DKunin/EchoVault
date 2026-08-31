import AVFoundation
import Foundation
import ImageIO

struct ExtractedAudioMetadata: Equatable, Sendable {
    let title: String?
    let artist: String?
    let albumTitle: String?
    let artworkData: Data?

    static let empty = ExtractedAudioMetadata(
        title: nil,
        artist: nil,
        albumTitle: nil,
        artworkData: nil
    )
}

protocol AudioMetadataReading: Sendable {
    func readMetadata(from url: URL) async throws -> ExtractedAudioMetadata
}

actor AVAudioMetadataReader: AudioMetadataReading {
    func readMetadata(from url: URL) async throws -> ExtractedAudioMetadata {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.commonMetadata)

        return ExtractedAudioMetadata(
            title: await stringValue(for: .commonIdentifierTitle, in: metadata),
            artist: await stringValue(for: .commonIdentifierArtist, in: metadata),
            albumTitle: await stringValue(for: .commonIdentifierAlbumName, in: metadata),
            artworkData: await artworkData(in: metadata)
        )
    }

    private func stringValue(
        for identifier: AVMetadataIdentifier,
        in metadata: [AVMetadataItem]
    ) async -> String? {
        for item in AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: identifier
        ) {
            guard let value = try? await item.load(.stringValue),
                let normalized = value.trimmedNonempty
            else {
                continue
            }
            return normalized
        }
        return nil
    }

    private func artworkData(in metadata: [AVMetadataItem]) async -> Data? {
        for item in AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .commonIdentifierArtwork
        ) {
            guard let data = try? await item.load(.dataValue),
                Self.isSafeArtwork(data)
            else {
                continue
            }
            return data
        }
        return nil
    }

    private static func isSafeArtwork(_ data: Data) -> Bool {
        let maximumBytes = 10 * 1_024 * 1_024
        guard !data.isEmpty,
            data.count <= maximumBytes,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0,
            height > 0
        else {
            return false
        }
        return width <= 4_096 && height <= 4_096 && width * height <= 16_000_000
    }
}

private extension String {
    var trimmedNonempty: String? {
        let result = trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
