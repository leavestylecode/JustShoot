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

    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    private func memoryCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 4096 }
        return max(cg.bytesPerRow * cg.height, 4096)
    }

    func cachedImage(cardId: String, maxPixel: Int) -> UIImage? {
        cache.object(forKey: "\(cardId)_\(maxPixel)" as NSString)
    }

    /// Async downsampled load. Returns the cached image on hit; otherwise
    /// produces a CGImageSource thumbnail on a detached task.
    func loadImage(card: FilmCard, maxPixel: Int) async -> UIImage? {
        await loadImage(imageName: card.image, cacheKey: card.id, maxPixel: maxPixel)
    }

    /// Same downsampling pipeline keyed by raw filename. Used by callers that
    /// don't have a `FilmCard` (e.g., the home grid mapping each preset to
    /// a hand-picked card image).
    func loadImage(imageName: String, cacheKey: String, maxPixel: Int) async -> UIImage? {
        let key = "\(cacheKey)_\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }

            let nameNoExt = (imageName as NSString).deletingPathExtension
            let ext = (imageName as NSString).pathExtension
            // Xcode 16 synchronized groups treat subfolders as logical groups by
            // default, so resources end up flat at bundle root. If the catalog
            // were ever flipped to folder-reference mode the lookup would need
            // `subdirectory: "cards"` — try that as a fallback.
            let url = Bundle.main.url(forResource: nameNoExt, withExtension: ext)
                ?? Bundle.main.url(forResource: nameNoExt, withExtension: ext, subdirectory: "cards")
            guard let url else {
                Log.gallery.error("filmcard_image_missing key=\(cacheKey, privacy: .public) name=\(imageName, privacy: .public)")
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
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, down as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cg)
            self.cache.setObject(image, forKey: key, cost: self.memoryCost(of: image))
            return image
        }.value
    }
}

@MainActor
@Observable
final class FilmCardLibrary {
    static let shared = FilmCardLibrary()

    private(set) var all: [FilmCard] = []
    private(set) var byBrand: [String: [FilmCard]] = [:]
    /// Brand names sorted by card count descending; ties broken alphabetically.
    /// Cards with no brand are kept in `all` but excluded from `byBrand` /
    /// `sortedBrands`, so callers must aggregate untagged cards separately.
    private(set) var sortedBrands: [String] = []
    private(set) var isLoaded = false

    private init() {}

    /// Parses cards.json and builds the indexes (parse runs detached; the main
    /// actor writes the resulting state).
    func loadIfNeeded() async {
        guard !isLoaded else { return }

        let timer = Log.perf("filmcard_load", logger: Log.gallery)
        let parsed: FilmCardBundle? = await Task.detached(priority: .userInitiated) { () -> FilmCardBundle? in
            let url = Bundle.main.url(forResource: "cards", withExtension: "json")
                ?? Bundle.main.url(forResource: "cards", withExtension: "json", subdirectory: "cards")
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(FilmCardBundle.self, from: data)
        }.value

        guard let parsed else {
            Log.gallery.error("filmcard_bundle_missing")
            isLoaded = true
            timer.end("missing")
            return
        }

        // Cards with nil/empty brand are intentionally not grouped — chip rendering
        // surfaces them via a separate "untagged" count under the "Other" bucket.
        let grouped = Dictionary(grouping: parsed.cards.filter { ($0.brand ?? "").isEmpty == false }) {
            $0.brand!
        }
        let brandOrder = grouped
            .map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
            }
            .map { $0.0 }

        self.all = parsed.cards
        self.byBrand = grouped
        self.sortedBrands = brandOrder
        self.isLoaded = true
        timer.end("count=\(parsed.cards.count) brands=\(brandOrder.count)")
    }

    /// Async downsampled card image load; cache hits return immediately.
    func image(for card: FilmCard, maxPixel: Int = 300) async -> UIImage? {
        await FilmCardImageCache.shared.loadImage(card: card, maxPixel: maxPixel)
    }
}
