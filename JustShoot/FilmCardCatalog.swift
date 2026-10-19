import Foundation
import UIKit
import ImageIO
import os

// MARK: - Film packaging card library
//
// Resources/cards.json + Resources/cards/*.heic — 550 cards after dedup,
// 96 distinct brands. Every optional field in the JSON may be null.

struct FilmCard: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let image: String
    let brand: String?
    let product: String?
    let format: String?
    let iso: Int?
    let process: String?
    let expiry: String?
    let type: String?
    let subtype: String?
    let quantity: String?
    let notes: String?
    let author: String?
    /// Coarse dominant-color classification produced by scripts/compute_card_colors.py.
    /// One of 10 buckets: red / orange / yellow / green / blue / purple / brown / black / white / gray.
    let color: String?
}

struct FilmCardBundle: Codable, Sendable {
    let version: Int
    let generatedAt: String
    let count: Int
    let imageSize: Int
    let cards: [FilmCard]
}

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

    func cachedImage(imageName: String, maxPixel: Int) -> UIImage? {
        cache.object(forKey: "\(imageName)_\(Self.pixelSize(for: maxPixel))" as NSString)
    }

    /// Async downsampled load. Returns the cached image on hit; otherwise
    /// produces a display-prepared thumbnail on the bounded blocking-image queue.
    func loadImage(card: FilmCard, maxPixel: Int) async -> UIImage? {
        await loadImage(imageName: card.image, maxPixel: maxPixel)
    }

    /// Same downsampling pipeline keyed by raw filename. Used by callers that
    /// don't have a `FilmCard` (e.g., the home grid mapping each preset to
    /// a hand-picked card image).
    func loadImage(imageName: String, maxPixel: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let maxPixel = Self.pixelSize(for: maxPixel)
        let key = "\(imageName)_\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached }

        return await requests.image(for: key) { [weak self] in
            guard let self else { return nil }
            if let cached = self.cache.object(forKey: key as NSString) { return cached }

            guard let image = self.decode(imageName, maxPixel) else { return nil }
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

    private(set) var catalog = FilmCardCatalogIndex(cards: [])
    private(set) var isLoaded = false
    private var loading: Task<FilmCardCatalogIndex?, Never>?

    private init() {}

    /// Parsing and all filter indexes are prepared once, away from MainActor.
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        let task: Task<FilmCardCatalogIndex?, Never>
        if let loading { task = loading }
        else {
            task = Task.detached(priority: .userInitiated) {
                let timer = Log.perf("filmcard_load", logger: Log.gallery)
                let url = Bundle.main.url(forResource: "cards", withExtension: "json")
                    ?? Bundle.main.url(forResource: "cards", withExtension: "json", subdirectory: "cards")
                guard let url, let data = try? Data(contentsOf: url) else {
                    timer.end("missing")
                    return nil
                }
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard let bundle = try? decoder.decode(FilmCardBundle.self, from: data) else {
                    timer.end("invalid")
                    return nil
                }
                let index = FilmCardCatalogIndex(cards: bundle.cards)
                timer.end("count=\(bundle.cards.count)")
                return index
            }
            loading = task
        }
        let prepared = await task.value
        guard !isLoaded else { return }
        if let prepared { catalog = prepared }
        else { Log.gallery.error("filmcard_bundle_missing") }
        isLoaded = true
        loading = nil
    }

    /// Async downsampled card image load; cache hits return immediately.
    func image(for card: FilmCard, maxPixel: Int = 300) async -> UIImage? {
        await FilmCardImageCache.shared.loadImage(card: card, maxPixel: maxPixel)
    }
}
