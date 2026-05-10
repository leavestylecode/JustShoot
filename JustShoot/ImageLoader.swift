import SwiftUI
import ImageIO
import UIKit
import os

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
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default

    /// 按设备物理内存自适应：上限 = min(128MB, RAM/32)
    /// 低端设备（2GB RAM）约 64MB；高端设备（8GB RAM）封顶 128MB
    private static func defaultCostLimit() -> Int {
        let mem = Int(ProcessInfo.processInfo.physicalMemory)
        return min(128 * 1024 * 1024, mem / 32)
    }

    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = Self.defaultCostLimit()
    }

    // MARK: - In-flight dedup
    //
    // 同一张图（同 key）被并发请求时——常见场景：handleTap 起一个 loadPreview，detail
    // mount 后 PagerImage.task 又起一个；schedulePreheat 跟 ThumbnailStripCell.task 撞同一
    // 张 600px thumb——旧实现会启动多个 Task.detached 并行 decode 同一帧，互相抢 CPU
    // cores，每个 decode 慢 ~2x，首张照片要等近 1 秒才出现。
    //
    // 新实现：每个 key 维护一个 in-flight Task，后续 caller 直接 await 已存在的 Task，
    // 同 key 同一份 decode。NSCache 命中走快路径不动；只有 miss 时才进 lock。
    //
    // 用 `OSAllocatedUnfairLock` 而不是 `NSLock`：NSLock 的 `lock()` / `unlock()` 在
    // Swift 6 完整并发模式下被标记为"unavailable from asynchronous contexts"（async 函数里
    // 调用会阻塞 cooperative thread pool 的 worker，破坏调度）。`OSAllocatedUnfairLock` 提供
    // 闭包式 `withLock` API，async 安全；持锁极短时间（dict 读写）足够快，不会影响调度。
    /// Dict 用 `String` key（不是 NSString）：String 是 Sendable，可以安全在 @Sendable 闭包里
    /// 捕获；NSString 不是，会触发"capture of 'key' with non-Sendable type"警告。
    /// NSCache 仍要 NSString，调用点用 `key as NSString` 临时转换即可。
    private struct InflightTasks {
        var previews: [String: Task<UIImage?, Never>] = [:]
        var thumbs: [String: Task<UIImage?, Never>] = [:]
    }
    /// `uncheckedState` 跳过 State: Sendable 约束——访问由锁串行化，State 内的 Task 实际不会
    /// 被并发触碰；Sendable 检查由我们用法担保，不交给类型系统强制。
    private let inflight = OSAllocatedUnfairLock(uncheckedState: InflightTasks())

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

    /// 便捷重载：在主 actor 上预取 `Photo` 的 imageData/id，再转发到 Sendable 版本。
    /// 调用点仍然写 `loadPreview(for: photo, ...)`，但 Sendable 契约由 @MainActor 担保。
    @MainActor
    func loadPreview(for photo: Photo, maxPixel: Int) async -> UIImage? {
        await loadPreview(imageData: photo.imageData, photoId: photo.id, maxPixel: maxPixel)
    }

    /// 同步查内存 cache（不触发 disk / 解码）。命中则零延迟，用于 view body 第一次评估时
    /// 给出占位图——避免 SwiftUI .task 启动那一帧露出黑屏。
    @MainActor
    func cachedPreview(for photoId: UUID, maxPixel: Int) -> UIImage? {
        cache.object(forKey: "preview_\(photoId.uuidString)_\(maxPixel)" as NSString)
    }

    @MainActor
    func cachedThumbnail(for photoId: UUID, maxPixel: Int) -> UIImage? {
        cache.object(forKey: "thumb_\(photoId.uuidString)_\(maxPixel)" as NSString)
    }

    /// 探测常见 thumb 尺寸（按高分辨率优先）找任意一份可用的——大屏 detail 页用 600，gallery
    /// 4 列网格用 264，列表头像用 88……不同来源算出的 maxPixel 不一样，cache key 也不一样，
    /// 旧实现单 key 查找会错过其他地方解码好的同一张图。
    ///
    /// 关键作用：用户从 gallery 点入 detail 那一帧——gallery 的 264 已在内存里，PagerImage
    /// 的占位 fallback 直接用它（虽然偏糊但**立刻有图**），后续 600 / preview 解码完再 soft-swap
    /// 升清，黑屏占位窗口被消除。
    @MainActor
    func anyCachedThumbnail(for photoId: UUID) -> UIImage? {
        // 高分→低分顺序遍历：找到第一个 hit 就用，保证拿到当前内存里"最好"的那份。
        let commonSizes = [1500, 1200, 800, 600, 400, 300, 264, 256, 200, 150, 120, 96, 88]
        let prefix = "thumb_\(photoId.uuidString)_"
        for size in commonSizes {
            if let img = cache.object(forKey: "\(prefix)\(size)" as NSString) {
                return img
            }
        }
        return nil
    }

    /// 加载大图预览。imageData/photoId 必须在调用者所在的 actor 上预取，避免跨 actor 传递非 Sendable 的 `Photo`。
    /// 同 key 并发请求会被 in-flight dedup 合并成一份 Task.detached——见 `inflight` 注释。
    func loadPreview(imageData: Data, photoId: UUID, maxPixel: Int) async -> UIImage? {
        let key = "preview_\(photoId.uuidString)_\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached }

        // Atomic check-and-register：同 key 已有 in-flight Task 就复用，否则注册新 Task。
        // 临界区只做 dict 读写（< 1µs），符合 OSAllocatedUnfairLock 的"持锁极短"用例。
        let task: Task<UIImage?, Never> = inflight.withLock { state in
            if let existing = state.previews[key] { return existing }
            let new = Task<UIImage?, Never>.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return nil }
                // disk hit 也走 detached：避免 caller 在 main actor 上同步读 17MB JPEG。
                if let url = self.previewURL(for: photoId, maxPixel: maxPixel),
                   self.fileManager.fileExists(atPath: url.path),
                   let data = try? Data(contentsOf: url),
                   let img = UIImage(data: data) {
                    self.cacheImage(img, forKey: key as NSString)
                    Log.gallery.debug("preview_disk_hit id=\(photoId.uuidString, privacy: .public) max=\(maxPixel)")
                    return img
                }
                let timer = Log.perf("preview_decode", logger: Log.gallery)
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: false
                ]
                guard let src = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else { return nil }
                let downOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 256),
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, downOptions as CFDictionary) else { return nil }
                let opaque = ImageLoader.makeOpaque(cgThumb)
                let image = UIImage(cgImage: opaque)
                self.cacheImage(image, forKey: key as NSString)
                if let url = self.previewURL(for: photoId, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.9) {
                    try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? jpeg.write(to: url, options: .atomic)
                }
                timer.end("id=\(photoId.uuidString) max=\(maxPixel) px=\(cgThumb.width)x\(cgThumb.height)")
                return image
            }
            state.previews[key] = new
            return new
        }

        let result = await task.value

        // 用 subscript-set-nil 让 closure body 自然返回 Void，避免 removeValue 的可选返回值被
        // withLock 透传给调用方触发"unused result"警告。
        inflight.withLock { state in
            state.previews[key] = nil
        }

        return result
    }

    /// 便捷重载：在主 actor 上预取 `Photo` 的 imageData/id。
    @MainActor
    func loadThumbnail(for photo: Photo, maxPixel: Int) async -> UIImage? {
        await loadThumbnail(imageData: photo.imageData, photoId: photo.id, maxPixel: maxPixel)
    }

    /// 加载缩略图。调用者须在 actor 上预取 imageData/photoId，避免跨 actor 传递 SwiftData `Photo` 模型。
    /// 同 key 并发请求会被 in-flight dedup 合并——常见场景：schedulePreheat 与 ThumbnailStripCell.task
    /// 同时请求同一张 600px thumb，旧实现会双重 decode 抢 CPU。
    func loadThumbnail(imageData: Data, photoId: UUID, maxPixel: Int) async -> UIImage? {
        let key = "thumb_\(photoId.uuidString)_\(maxPixel)"
        if let cached = cache.object(forKey: key as NSString) { return cached }

        let task: Task<UIImage?, Never> = inflight.withLock { state in
            if let existing = state.thumbs[key] { return existing }
            let new = Task<UIImage?, Never>.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return nil }
                if let url = self.thumbnailURL(for: photoId, maxPixel: maxPixel),
                   self.fileManager.fileExists(atPath: url.path),
                   let data = try? Data(contentsOf: url),
                   let img = UIImage(data: data) {
                    self.cacheImage(img, forKey: key as NSString)
                    return img
                }
                let options: [CFString: Any] = [
                    kCGImageSourceShouldCache: false,
                    kCGImageSourceShouldCacheImmediately: false
                ]
                guard let src = CGImageSourceCreateWithData(imageData as CFData, options as CFDictionary) else { return nil }
                let thumbOptions: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 96),
                    kCGImageSourceCreateThumbnailWithTransform: true
                ]
                guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else { return nil }
                let opaque = ImageLoader.makeOpaque(cgThumb)
                let image = UIImage(cgImage: opaque)
                self.cacheImage(image, forKey: key as NSString)
                if let url = self.thumbnailURL(for: photoId, maxPixel: maxPixel), let jpeg = image.jpegData(compressionQuality: 0.85) {
                    try? self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? jpeg.write(to: url, options: .atomic)
                }
                return image
            }
            state.thumbs[key] = new
            return new
        }

        let result = await task.value

        inflight.withLock { state in
            state.thumbs[key] = nil
        }

        return result
    }

    private func thumbsDirectory() -> URL? {
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDir.appendingPathComponent("Thumbs", isDirectory: true)
    }

    private func thumbnailURL(for photoId: UUID, maxPixel: Int) -> URL? {
        guard let dir = thumbsDirectory() else { return nil }
        return dir.appendingPathComponent("\(photoId.uuidString)_t_\(maxPixel).jpg")
    }

    private func previewDirectory() -> URL? {
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDir.appendingPathComponent("Previews", isDirectory: true)
    }

    private func previewURL(for photoId: UUID, maxPixel: Int) -> URL? {
        guard let dir = previewDirectory() else { return nil }
        return dir.appendingPathComponent("\(photoId.uuidString)_p_\(maxPixel).jpg")
    }

    func clearCache() {
        cache.removeAllObjects()
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
}
