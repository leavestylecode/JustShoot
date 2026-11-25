import Combine
import ImageIO
import UIKit
import os

/// ImageIO/HEVC may synchronously wait for decoder work. Keep those waits off Swift's
/// cooperative executor and bound parallel decodes across covers, thumbnails and exports.
final class BlockingImageWork: @unchecked Sendable {
    static let shared = BlockingImageWork()
    private let queue: OperationQueue
    private let active = OSAllocatedUnfairLock(initialState: 0)

    var diagnosticFields: String {
        let running = active.withLock { $0 }
        return "image_work_active=\(running) image_work_queued=\(max(0, queue.operationCount - running))"
    }

    init(maximumConcurrentOperations: Int = 2, label: String = "com.justshoot.image-work") {
        queue = OperationQueue()
        queue.name = label
        // The queue's QoS is a floor. Give interactive requests their priority on
        // the operation so background capture thumbnails can run at utility.
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(1, maximumConcurrentOperations)
    }

    func run<Value: Sendable>(_ work: @escaping @Sendable () -> Value?,
                              qualityOfService: QualityOfService = .userInitiated) async -> Value? {
        let state = PhotoRequestState<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else { return }
                let operation = BlockOperation {
                    guard !state.isFinished else { return }
                    self.active.withLock { $0 += 1 }
                    defer { self.active.withLock { $0 -= 1 } }
                    state.finish(autoreleasepool(invoking: work))
                }
                operation.qualityOfService = qualityOfService
                queue.addOperation(operation)
            }
        } onCancel: {
            _ = state.cancel()
        }
    }
}

/// iOS 26 deprecated `UIScreen.main`. For non-view contexts we still need
/// a screen handle for full-resolution preview sizing — fish it out of the
/// active window scene.
@MainActor
func currentScreen() -> UIScreen? {
    UIApplication.shared.connectedScenes
        .lazy
        .compactMap { $0 as? UIWindowScene }
        .first?
        .screen
}

// MARK: - 图片加载器
// @unchecked Sendable：NSCache 和 FileManager.default 本身线程安全，
// init 后所有可变状态都仅通过线程安全 API 写入
final class ImageLoader: ObservableObject, @unchecked Sendable {
    static let shared = ImageLoader()
    private let cache = NSCache<NSString, UIImage>()          // 缩略图
    /// 详情大图预览单独一个 cache——大图单张 ~24MB（2868×2152 RGBA8），若和缩略图共用，进详情时
    /// 网格缩略图还占着缓存，±N 预览环一进来就把彼此挤爆、反复淘汰再从磁盘重载（disk_hit 抖动 + 卡顿）。
    /// 隔离后预览只和预览竞争，预加载环稳稳命中内存。
    private let previewCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let requests: SharedImageRequests
    private let cacheDirectory: URL?
    private let previewGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// 缩略图缓存上限：min(128MB, RAM/32)。低端 2GB≈64MB，高端 8GB 封顶 128MB。
    private static func defaultCostLimit() -> Int {
        let mem = Int(ProcessInfo.processInfo.physicalMemory)
        return min(128 * 1024 * 1024, mem / 32)
    }

    /// Keep only the current/adjacent preview window alongside the thumbnail cache.
    private static func previewCostLimit() -> Int {
        let mem = Int(ProcessInfo.processInfo.physicalMemory)
        return min(96 * 1024 * 1024, mem / 32)
    }

    init(worker: BlockingImageWork = .shared, cacheDirectory: URL? = nil) {
        requests = SharedImageRequests(worker: worker)
        self.cacheDirectory = cacheDirectory
        cache.countLimit = 50
        cache.totalCostLimit = Self.defaultCostLimit()
        previewCache.countLimit = 3
        previewCache.totalCostLimit = Self.previewCostLimit()
    }

    // Each photo/size has one decode. Consumers can cancel independently; the last
    // cancellation removes queued work without waiting for a running ImageIO codec.

    /// UIImage 的近似内存占用（字节）：解码后按 RGBA8 估算，未解码也安全
    private func memoryCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else {
            let pixels = Int(image.size.width * image.size.height * image.scale * image.scale)
            return max(pixels * 4, 4096)
        }
        return max(cg.bytesPerRow * cg.height, 4096)
    }

    private func cacheImage(_ image: UIImage, forKey key: NSString) {
        cache.setObject(image, forKey: key, cost: memoryCost(of: image))
    }

    private func cachePreview(_ image: UIImage, forKey key: NSString, generation: UInt64) {
        let key = key as String
        previewGeneration.withLock {
            guard $0 == generation else { return }
            previewCache.setObject(image, forKey: key as NSString, cost: memoryCost(of: image))
        }
    }

    /// 把带 alpha channel 的 CGImage 重绘成 opaque RGB，去掉无意义的 alpha 字节。
    /// 触发场景：HEIC 源经 CGImageSourceCreateThumbnailAtIndex 出来的 CGImage 默认带 RGBA，
    /// 内容明明 opaque——直接 jpegData 会报"opaque image with AlphaLast"且文件多 25%。
    /// 重绘到 noneSkipFirst（XRGB）后存盘即可消除 ImageIO 警告，同时减小文件、加快解码。
    static func makeOpaque(_ cgImage: CGImage) -> CGImage {
        let w = cgImage.width
        let h = cgImage.height
        let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return cgImage }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? cgImage
    }

    /// 同步查内存 cache（不触发 disk / 解码）。命中则零延迟，用于 view body 第一次评估时
    /// 给出占位图——避免 SwiftUI .task 启动那一帧露出黑屏。
    @MainActor
    func cachedPreview(for photoId: UUID, maxPixel: Int) -> UIImage? {
        let maxPixel = max(maxPixel, 256)
        return previewCache.object(forKey: "preview_\(photoId.uuidString)_\(maxPixel)" as NSString)
    }

    @MainActor
    func cachedThumbnail(for photoId: UUID, maxPixel: Int) -> UIImage? {
        let maxPixel = max(maxPixel, 96)
        return cache.object(forKey: "thumb_\(photoId.uuidString)_\(maxPixel)" as NSString)
    }

    /// 探测常见 thumb 尺寸（按高分辨率优先）找任意一份可用的——详情占位用 160，gallery
    /// 4 列网格用 264，列表头像用 88……不同来源算出的 maxPixel 不一样，cache key 也不一样，
    /// 旧实现单 key 查找会错过其他地方解码好的同一张图。
    ///
    /// 关键作用：用户从 gallery 点入 detail 那一帧——gallery 的 264 已在内存里，PagerImage
    /// 的占位 fallback 直接用它（虽然偏糊但**立刻有图**），后续 preview 解码完再 soft-swap
    /// 升清，黑屏占位窗口被消除。
    @MainActor
    func anyCachedThumbnail(for photoId: UUID) -> UIImage? {
        // 高分→低分顺序遍历：找到第一个 hit 就用，保证拿到当前内存里"最好"的那份。
        let commonSizes = [1500, 1200, 800, 600, 400, 300, 264, 256, 200, 192, 160, 150, 120, 96, 88]
        let prefix = "thumb_\(photoId.uuidString)_"
        for size in commonSizes {
            if let img = cache.object(forKey: "\(prefix)\(size)" as NSString) {
                return img
            }
        }
        return nil
    }

    /// 只查 NSCache + 磁盘缩略图（按 photoId+maxPixel），命中返回，未命中返回 nil——**不 fault 原图
    /// blob、不解码原图**。相册网格 cell / 预取优先走这条：已生成过缩略图的照片滚动时不再把整张大图
    /// blob fault 进主线程（SwiftData externalStorage 读必须在主 actor，是滚动卡顿的主因）。
    func cachedOrDiskThumbnail(photoId: UUID, maxPixel: Int) async -> UIImage? {
        await cachedOrDiskImage(photoId: photoId, maxPixel: maxPixel, preview: false)
    }

    func cachedOrDiskPreview(photoId: UUID, maxPixel: Int) async -> UIImage? {
        await cachedOrDiskImage(photoId: photoId, maxPixel: maxPixel, preview: true)
    }

    private func cachedOrDiskImage(photoId: UUID, maxPixel: Int, preview: Bool) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let maxPixel = max(maxPixel, preview ? 256 : 96)
        let key = "\(preview ? "preview" : "thumb")_\(photoId.uuidString)_\(maxPixel)"
        let imageCache = preview ? previewCache : cache
        let generation = previewGeneration.withLock { $0 }
        if let cached = imageCache.object(forKey: key as NSString) { return cached }
        guard let url = preview ? previewURL(for: photoId, maxPixel: maxPixel)
            : thumbnailURL(for: photoId, maxPixel: maxPixel) else { return nil }
        return await requests.image(for: "disk_\(key)") { [weak self] in
            guard let self else { return nil }
            let imageCache = preview ? self.previewCache : self.cache
            if let cached = imageCache.object(forKey: key as NSString) { return cached }
            guard self.fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let img = UIImage(data: data)?.preparingForDisplay() else { return nil }
            if preview { self.cachePreview(img, forKey: key as NSString, generation: generation) }
            else { self.cacheImage(img, forKey: key as NSString) }
            return img
        }
    }

    /// 加载大图预览。imageData/photoId 必须在调用者所在的 actor 上预取，避免跨 actor 传递非 Sendable 的 `Photo`。
    /// Concurrent consumers share a decode; cancellation stops waiting immediately.
    func loadPreview(imageData: Data, photoId: UUID, maxPixel: Int) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        // 钳到解码下限后再算 key/URL/解码尺寸：三者用同一有效值，避免 maxPixel=100 与 256
        // 解出同样像素却存成两份（重复 decode + 重复落盘）。cachedPreview 同步快路径同样钳值。
        let maxPixel = max(maxPixel, 256)
        let key = "preview_\(photoId.uuidString)_\(maxPixel)"
        let generation = previewGeneration.withLock { $0 }
        if let cached = previewCache.object(forKey: key as NSString) { return cached }

        return await requests.image(for: key) { [weak self] in
            guard let self else { return nil }
            if let cached = self.previewCache.object(forKey: key as NSString) { return cached }
            // disk hit 也走专用队列：避免 caller 在 main actor 上同步读 17MB JPEG。
            if let url = self.previewURL(for: photoId, maxPixel: maxPixel),
               self.fileManager.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let img = UIImage(data: data)?.preparingForDisplay() {
                self.cachePreview(img, forKey: key as NSString, generation: generation)
                Log.gallery.debug("preview_disk_hit id=\(photoId.uuidString, privacy: .public) max=\(maxPixel)")
                return img
            }
            let timer = Log.perf("preview_decode", logger: Log.gallery)
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ]
            guard let src = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else { return nil }
            guard let cgThumb = Self.downsample(src, maxPixel: maxPixel) else { return nil }
            let opaque = ImageLoader.makeOpaque(cgThumb)
            let image = UIImage(cgImage: opaque)
            self.cachePreview(image, forKey: key as NSString, generation: generation)
            if let url = self.previewURL(for: photoId, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.9) {
                try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: url, options: .atomic)
            }
            timer.end("id=\(photoId.uuidString) max=\(maxPixel) px=\(cgThumb.width)x\(cgThumb.height)")
            return image
        }
    }

    /// 加载缩略图。调用者须在 actor 上预取 imageData/photoId，避免跨 actor 传递 SwiftData `Photo` 模型。
    /// 同 key 并发请求会被 in-flight dedup 合并——常见场景：schedulePreheat 与 ThumbnailStripCell.task
    /// 同时请求同一张 600px thumb，旧实现会双重 decode 抢 CPU。
    func loadThumbnail(imageData: Data, photoId: UUID, maxPixel: Int,
                       qualityOfService: QualityOfService = .userInitiated) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        // 同 loadPreview：钳到解码下限再算 key/URL/解码尺寸，避免 88 与 96 解出同像素存两份。
        let maxPixel = max(maxPixel, 96)
        let key = "thumb_\(photoId.uuidString)_\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached }

        return await requests.image(for: key, qualityOfService: qualityOfService) { [weak self] in
            guard let self else { return nil }
            if let cached = self.cache.object(forKey: key as NSString) { return cached }
            if let url = self.thumbnailURL(for: photoId, maxPixel: maxPixel),
               self.fileManager.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let img = UIImage(data: data)?.preparingForDisplay() {
                self.cacheImage(img, forKey: key as NSString)
                return img
            }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ]
            guard let src = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else { return nil }
            guard let cgThumb = Self.downsample(src, maxPixel: maxPixel) else { return nil }
            let opaque = ImageLoader.makeOpaque(cgThumb)
            let image = UIImage(cgImage: opaque)
            self.cacheImage(image, forKey: key as NSString)
            if let url = self.thumbnailURL(for: photoId, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.85) {
                try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? jpeg.write(to: url, options: .atomic)
            }
            return image
        }
    }

    static func downsample(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        // ImageIO's HEIF decoder can reject a thumbnail request larger than a small original.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let edge = max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge > 0 ? min(edge, maxPixel) : maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func thumbsDirectory() -> URL? {
        guard let cacheDir = cacheDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDir.appendingPathComponent("Thumbs", isDirectory: true)
    }

    private func thumbnailURL(for photoId: UUID, maxPixel: Int) -> URL? {
        guard let dir = thumbsDirectory() else { return nil }
        return dir.appendingPathComponent("\(photoId.uuidString)_t_\(maxPixel).jpg")
    }

    private func previewDirectory() -> URL? {
        guard let cacheDir = cacheDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDir.appendingPathComponent("Previews", isDirectory: true)
    }

    private func previewURL(for photoId: UUID, maxPixel: Int) -> URL? {
        guard let dir = previewDirectory() else { return nil }
        return dir.appendingPathComponent("\(photoId.uuidString)_p_\(maxPixel).jpg")
    }

    func clearCache() {
        cache.removeAllObjects()
        clearPreviewCache()
    }

    func clearPreviewCache() {
        previewGeneration.withLock {
            $0 &+= 1
            previewCache.removeAllObjects()
        }
    }

    /// 删除指定照片的磁盘缓存文件。
    /// 内存 NSCache 不主动清——cell 已 unmount，key 不会再被命中，让 NSCache 自然按 cost/count 淘汰。
    /// 主动移除需要遍历 key，但 NSCache 不暴露遍历 API，按写死常见尺寸列表去 remove 与实际写入尺寸
    /// 几乎对不上（cell 用 width × displayScale 算出来的尺寸），是 dead code。
    func removeDiskCache(for photoId: UUID) {
        let fm = fileManager
        let prefix = photoId.uuidString
        for dir in [thumbsDirectory(), previewDirectory()] {
            guard let dir, let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files where file.hasPrefix(prefix) {
                try? fm.removeItem(at: dir.appendingPathComponent(file))
            }
        }
    }

    /// 孤儿对账（启动维护用）：删掉「不属于任何现存照片」的磁盘缓存文件——行删除与缓存清理
    /// 之间崩溃留下的残留。keepingIDs 是现存全部 Photo.id（uuidString），文件名格式
    /// `<UUID>_t_<px>.jpg` / `<UUID>_p_<px>.jpg`，按下划线前的 UUID 段比对。
    /// 保守原则：只要 id 还有行就保留（即便该照片已迁入相册、缓存实际不再被读）——误删零风险，
    /// 死文件由 removeDiskCache 在删行/迁移时点杀。
    func pruneOrphanDiskCache(keepingIDs ids: Set<String>) {
        var removed = 0
        for dir in [thumbsDirectory(), previewDirectory()] {
            guard let dir, let files = try? fileManager.contentsOfDirectory(atPath: dir.path) else { continue }
            for file in files {
                guard let uuid = file.split(separator: "_").first, !ids.contains(String(uuid)) else { continue }
                try? fileManager.removeItem(at: dir.appendingPathComponent(file))
                removed += 1
            }
        }
        if removed > 0 {
            Log.gallery.info("orphan_disk_cache_pruned count=\(removed)")
        }
    }
}
