import ImageIO
import UIKit

final class LoadedArtworkImage: @unchecked Sendable {
    let image: UIImage
    let cost: Int

    init(image: UIImage, cost: Int) {
        self.image = image
        self.cost = cost
    }
}

@MainActor
enum ArtworkImageCache {
    private static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private static var inFlightLoads: [NSString: Task<LoadedArtworkImage?, Never>] = [:]

    static func image(at url: URL, maxPixelSize: Int) async -> UIImage? {
        let key = "\(url.standardizedFileURL.path)#\(maxPixelSize)" as NSString
        if let image = images.object(forKey: key) {
            return image
        }

        let loadTask: Task<LoadedArtworkImage?, Never>
        if let inFlightLoad = inFlightLoads[key] {
            loadTask = inFlightLoad
        } else {
            let newLoad = Task {
                await ArtworkImageLoader.load(at: url, maxPixelSize: maxPixelSize)
            }
            inFlightLoads[key] = newLoad
            loadTask = newLoad
        }

        let loaded = await loadTask.value
        inFlightLoads[key] = nil
        guard let loaded else {
            return nil
        }
        images.setObject(loaded.image, forKey: key, cost: loaded.cost)
        return loaded.image
    }
}

enum ArtworkImageLoader {
    static func load(at url: URL, maxPixelSize: Int) async -> LoadedArtworkImage? {
        let loadTask = Task.detached(priority: .utility) { () -> LoadedArtworkImage? in
            guard !Task.isCancelled,
                let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            else {
                return nil
            }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
            ]
            guard !Task.isCancelled,
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options as CFDictionary
                )
            else {
                return nil
            }

            let uiImage = UIImage(cgImage: image)
            return LoadedArtworkImage(
                image: uiImage,
                cost: image.bytesPerRow * image.height
            )
        }
        return await withTaskCancellationHandler {
            await loadTask.value
        } onCancel: {
            loadTask.cancel()
        }
    }
}
