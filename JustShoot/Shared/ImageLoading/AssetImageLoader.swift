import os
import Photos
import UIKit

/// PhotoKit handles size caching and iCloud fetches. The small memory cache also supplies
/// synchronous first-frame placeholders when cells are reused.
final class AssetImageLoader: @unchecked Sendable {
    static let shared = AssetImageLoader()
    private let manager = PHCachingImageManager()
    private let versions = OSAllocatedUnfairLock(initialState: [String: UInt64]())
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // Nine-column grids can show more than 120 small thumbnails at once.
        cache.countLimit = 360
        let mem = Int(ProcessInfo.processInfo.physicalMemory)
        cache.totalCostLimit = min(128 * 1024 * 1024, mem / 32)
    }

    private func cost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 4096 }
        return max(cg.bytesPerRow * cg.height, 4096)
    }

    func asset(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func thumbnailKey(id: String, maxPixel: Int) -> NSString {
        let version = versions.withLock { $0[id, default: 0] }
        return "\(id)_\(version)_\(maxPixel)" as NSString
    }

    func invalidate(id: String) {
        versions.withLock { $0[id, default: 0] += 1 }
    }

    /// 同步查内存缓存（不发起请求）。命中即零延迟。
    func cachedThumbnail(id: String, maxPixel: Int) -> UIImage? {
        cache.object(forKey: thumbnailKey(id: id, maxPixel: maxPixel))
    }

    /// Grid cells can display an opportunistic preview while waiting for the cacheable image.
    func thumbnail(id: String, maxPixel: Int, trace: DiagnosticTrace? = nil,
                   onDegraded: (@Sendable (UIImage) -> Void)? = nil) async -> UIImage? {
        let key = thumbnailKey(id: id, maxPixel: maxPixel)
        if let cached = cache.object(forKey: key) { return cached }
        let img = await requestImage(id: id, targetSize: CGSize(width: maxPixel, height: maxPixel),
                                     contentMode: .aspectFill, resize: .fast, trace: trace, kind: "thumbnail",
                                     onDegraded: onDegraded)
        if let img { cache.setObject(img, forKey: key, cost: cost(img)) }
        return img
    }

    /// async 单发大图预览。aspectFit + exact 精确缩放。
    func preview(id: String, maxPixel: Int, trace: DiagnosticTrace? = nil) async -> UIImage? {
        await requestImage(id: id, targetSize: CGSize(width: maxPixel, height: maxPixel),
                           contentMode: .aspectFit, resize: .exact, trace: trace, kind: "preview")
    }

    private func requestImage(id: String, targetSize: CGSize, contentMode: PHImageContentMode,
                              resize: PHImageRequestOptionsResizeMode, trace: DiagnosticTrace?, kind: String,
                              onDegraded: (@Sendable (UIImage) -> Void)? = nil) async -> UIImage? {
        let request = trace?.span("photo_asset_request", "kind=\(kind) max_pixel=\(Int(max(targetSize.width, targetSize.height)))")
        guard !Task.isCancelled else { request?.end("cancelled"); return nil }
        guard let asset = asset(id: id) else {
            request?.end("missing_asset", "authorization=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
            return nil
        }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = onDegraded == nil ? .highQualityFormat : .opportunistic
        opts.resizeMode = resize
        opts.isNetworkAccessAllowed = true
        return await performRequest(span: request, onDegraded: onDegraded) { handler in
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: opts, resultHandler: handler)
        }
    }

    /// 单发请求统一入口。超时兜底:PhotoKit 在授权边缘态（PLPrivacy 判定需要弹窗但弹不出）/库索引
    /// 异常时,`requestImage` 的 resultHandler 可能**永不回调**——上层 `.task` 挂死、详情页停在
    /// 无限 spinner 且诊断 span 永不结束（真机 2026-10-10 全黑查看事件的形态）。12s 未交付按取消
    /// 落定,span 记录 timeout + 当前授权状态,`loadFailed` 得以置位,UI 显示失败态 + 可重试。
    private func performRequest<Value: Sendable>(span: DiagnosticSpan?,
        timeout: TimeInterval = 12,
        onDegraded: (@Sendable (Value) -> Void)? = nil,
        start: (@escaping (Value?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID) async -> Value? {
        let state = PhotoRequestState<Value>()
        let timeoutTask = Task(priority: .utility) {
            guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
            let cancellation = state.cancel()
            if cancellation.requestID != PHInvalidImageRequestID { manager.cancelImageRequest(cancellation.requestID) }
            if cancellation.didFinish {
                span?.end("timeout", "authorization=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
            }
        }
        defer { timeoutTask.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else { return }
                let requestID = start { value, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    let error = info?[PHImageErrorKey] as? NSError
                    if !cancelled, error == nil, (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                        if let value, !state.isFinished { onDegraded?(value) }
                        return
                    }
                    let result = cancelled || error != nil ? nil : value
                    guard state.finish(result) else { return }
                    span?.end(cancelled ? "cancelled" : error != nil ? "error" : value == nil ? "empty" : "ok",
                        error.map { Diagnostics.errorFields($0) } ?? "")
                }
                if state.register(requestID) { manager.cancelImageRequest(requestID) }
            }
        } onCancel: {
            let cancellation = state.cancel()
            if cancellation.requestID != PHInvalidImageRequestID { self.manager.cancelImageRequest(cancellation.requestID) }
            if cancellation.didFinish { span?.end("cancelled") }
        }
    }

    /// 加载 PHLivePhoto（详情页长按播放用）。targetSize 给屏幕尺寸即可；PHImageManager 自带缓存 +
    /// iCloud 回源。静态占位不结束请求；等待完整动态资源，退出页面时可以取消。
    func livePhoto(id: String, targetSize: CGSize, trace: DiagnosticTrace? = nil) async -> PHLivePhoto? {
        let request = trace?.span("photo_asset_request", "kind=live")
        guard !Task.isCancelled else { request?.end("cancelled"); return nil }
        guard let asset = asset(id: id) else { request?.end("missing_asset"); return nil }
        let opts = PHLivePhotoRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return await performRequest(span: request) { handler in
            manager.requestLivePhoto(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: opts, resultHandler: handler)
        }
    }

    /// 原始字节（用于 EXIF 解析）。
    func imageData(id: String, trace: DiagnosticTrace? = nil, original: Bool = false, timeout: TimeInterval = 12) async -> Data? {
        let request = trace?.span("photo_asset_request", "kind=original")
        guard !Task.isCancelled else { request?.end("cancelled"); return nil }
        guard let asset = asset(id: id) else { request?.end("missing_asset"); return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        if original { opts.version = .original }
        return await performRequest(span: request, timeout: timeout) { handler in
            manager.requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, info in
                handler(data, info)
            }
        }
    }

    /// 预取（滚动 prefetch / 详情翻页预热）：PHCachingImageManager 在 idle 时段后台预解码到目标尺寸。
    func startCaching(ids: [String], maxPixel: Int) {
        guard !ids.isEmpty else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { a, _, _ in assets.append(a) }
        guard !assets.isEmpty else { return }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        manager.startCachingImages(for: assets, targetSize: CGSize(width: maxPixel, height: maxPixel),
                                   contentMode: .aspectFill, options: opts)
    }

    func stopCaching(ids: [String], maxPixel: Int) {
        guard !ids.isEmpty else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        manager.stopCachingImages(for: assets, targetSize: CGSize(width: maxPixel, height: maxPixel),
                                  contentMode: .aspectFill, options: opts)
    }

    func clearCache() {
        cache.removeAllObjects()
        manager.stopCachingImagesForAllAssets()
    }
}
