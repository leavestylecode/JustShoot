import Foundation
import UIKit
import ImageIO
import os

/// NSCache-backed image loader for cards. Mirrors `ImageLoader`'s pattern but uses
/// its own cache so the gallery's loaded photos and library card thumbnails don't
/// evict each other.
final class FilmCardImageCache: @unchecked Sendable {
    static let shared = FilmCardImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private let requests: SharedImageRequests
    private let decode: @Sendable (String, Int) -> UIImage?

    init(worker: BlockingImageWork = .shared,
         decode: @escaping @Sendable (String, Int) -> UIImage? = FilmCardImageCache.decodeImage) {
        requests = SharedImageRequests(worker: worker)
        self.decode = decode
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    private func memoryCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 4096 }
        return max(cg.bytesPerRow * cg.height, 4096)
    }

    /// Nearby layouts share decoded images; bundled cards have a 1024px long edge.
    static func pixelSize(for requested: Int) -> Int {
        for size in [128, 256, 384, 640] where requested <= size { return size }
        return 1024
    }

    private static func key(_ imageName: String, pixel: Int, preset: FilmPreset? = nil) -> String {
        let original = "\(imageName)_\(pixel)"
        return preset.map { "\(original)/\($0.rawValue)" } ?? original
    }

    func cachedImage(imageName: String, maxPixel: Int, gradedWith preset: FilmPreset? = nil) -> UIImage? {
        cache.object(forKey: Self.key(imageName, pixel: Self.pixelSize(for: maxPixel), preset: preset) as NSString)
    }

    func loadImage(imageName: String, maxPixel: Int, gradedWith preset: FilmPreset? = nil) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let pixel = Self.pixelSize(for: maxPixel)
        let key = Self.key(imageName, pixel: pixel, preset: preset)
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let original = await image(for: Self.key(imageName, pixel: pixel)) { [decode] in
            decode(imageName, pixel)
        }
        guard let preset else { return original }
        guard let input = original?.cgImage, !Task.isCancelled else { return nil }
        return await image(for: key) {
            guard let output = FilmProcessor.shared.gradedPreview(input, preset: preset) else { return nil }
            return UIImage(cgImage: output)
        }
    }

    /// Decode and grade on the bounded worker. Both stages share requests and the same memory budget.
    private func image(for key: String, load: @escaping @Sendable () -> UIImage?) async -> UIImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        return await requests.image(for: key) { [weak self] in
            guard let self else { return nil }
            if let cached = self.cache.object(forKey: key as NSString) { return cached }
            guard let image = load() else { return nil }
            self.cache.setObject(image, forKey: key as NSString, cost: self.memoryCost(of: image))
            return image
        }
    }

    private static func decodeImage(imageName: String, maxPixel: Int) -> UIImage? {
        let nameNoExt = (imageName as NSString).deletingPathExtension
        let ext = (imageName as NSString).pathExtension
        // Xcode 16 synchronized groups treat subfolders as logical groups by
        // default, so resources end up flat at bundle root. If the catalog
        // were ever flipped to folder-reference mode the lookup would need
        // `subdirectory: "cards"` — try that as a fallback.
        let url = Bundle.main.url(forResource: nameNoExt, withExtension: ext)
            ?? Bundle.main.url(forResource: nameNoExt, withExtension: ext, subdirectory: "cards")
        guard let url else {
            Log.gallery.error("filmcard_image_missing name=\(imageName, privacy: .public)")
            return nil
        }

        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else { return nil }
        let down: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 96),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, down as CFDictionary) else { return nil }
        // This synchronous UIKit decode runs only on the bounded image worker, never
        // MainActor. Return the prepared object itself, not its lazily decoded original.
        guard let image = UIImage(cgImage: cg).preparingForDisplay() else { return nil }
        return image
    }
}

@MainActor
@Observable
final class FilmCardLibrary {
    static let shared = FilmCardLibrary()

    enum LoadState { case loading, ready, failed }
    private(set) var presets: [FilmPreset] = []
    private(set) var loadState = LoadState.loading
    private var loading: Task<[FilmPreset]?, Never>?
    private let loadCatalog: @Sendable () -> [FilmPreset]?

    init(loadCatalog: @escaping @Sendable () -> [FilmPreset]? = FilmCardLibrary.bundledCatalog) {
        self.loadCatalog = loadCatalog
    }

    /// The LUT-backed catalog is prepared once, away from MainActor.
    func loadIfNeeded() async {
        guard loadState != .ready else { return }
        let task: Task<[FilmPreset]?, Never>
        if let loading { task = loading }
        else {
            loadState = .loading
            task = Task.detached(priority: .userInitiated) { [loadCatalog] in loadCatalog() }
            loading = task
        }
        let prepared = await task.value
        guard loading == task else { return }
        loading = nil
        if let prepared {
            presets = prepared
            loadState = .ready
        } else {
            loadState = .failed
            Log.gallery.error("filmcard_bundle_missing")
        }
    }

    nonisolated private static func bundledCatalog() -> [FilmPreset]? {
        let timer = Log.perf("filmcard_load", logger: Log.gallery)
        let presets = FilmLUTCatalog.availablePresets()
        timer.end("count=\(presets?.count ?? 0)")
        return presets
    }
}
