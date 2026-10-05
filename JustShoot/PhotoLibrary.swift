import Photos
import UIKit
import SwiftData
import CoreLocation
import ImageIO
import os

// MARK: - 系统相册为真相源（Photos library is the source of truth）
//
// 架构：拍摄的成品照片直接写入系统相册的 "JustShoot" 自定义相簿，SwiftData 只保留轻量索引
// （PHAsset.localIdentifier + 胶片元数据）。好处：照片真正进用户图库、白拿 iCloud 同步/备份、
// 卸载不丢、滚动缩略图走系统级 PHCachingImageManager。app 内画廊 = 基于这些 identifier 的策展层。
//
// 兼容/兜底：拍摄时若相册写入失败（权限拒绝），把字节暂存进 Photo.imageData，待授权后由
// PhotoSaver.migrateInternalPhotos（reconcileWithLibrary 的第一步）迁入相册；旧版本遗留的
// 内部照片同样经它在首次授权后迁移，迁入后 blob 置 nil 释放 externalStorage。

/// 把可变值塞进 @Sendable performChanges 闭包用的轻量盒子（PhotoKit 的 change block 在
/// Swift 6 strict concurrency 下是 @Sendable，无法直接捕获并回写局部 var）。
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

enum PhotoLibraryError: Error {
    case notAuthorized
    case saveFailed
}

enum PhotoLibrary {
    static let albumTitle = "JustShoot"

    // MARK: - 授权（读写）
    //
    // 真相源在相册，所以需要 .readWrite（写入 + 回读自建资产）。.limited 也可用：app 始终能
    // 读取自己创建的资产。仅在 .notDetermined 时弹一次系统授权，已决定状态不重复打扰。
    static func ensureAuthorized(trace: DiagnosticTrace? = nil) async throws {
        let authorization = trace?.span("photos_authorization")
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status: PHAuthorizationStatus = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            : current
        authorization?.end("resolved", "before=\(current.rawValue) after=\(status.rawValue)")
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.notAuthorized
        }
    }

    static var isAuthorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    private static func captureFilename(_ id: UUID, imageData: Data) -> String {
        let source = CGImageSourceCreateWithData(imageData as CFData, nil)
        let type = source.flatMap { CGImageSourceGetType($0) } as String?
        return "JustShoot_\(id.uuidString)." + (type == "public.jpeg" ? "jpg" : "heic")
    }

    private static func captureIdentifier(of asset: PHAsset) -> UUID? {
        for resource in PHAssetResource.assetResources(for: asset) where resource.type == .photo {
            let filename: String
            if #available(iOS 27, *) { filename = resource.filename ?? "" }
            else { filename = resource.originalFilename }
            guard filename.hasPrefix("JustShoot_") else { continue }
            let stem = (filename as NSString).deletingPathExtension
            return UUID(uuidString: String(stem.dropFirst("JustShoot_".count)))
        }
        return nil
    }

    static func findCapture(id: UUID, creationDate: Date) -> String? {
        guard isAuthorized else { return nil }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                        creationDate.addingTimeInterval(-1) as NSDate,
                                        creationDate.addingTimeInterval(1) as NSDate)
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var identifier: String?
        assets.enumerateObjects { asset, _, stop in
            if captureIdentifier(of: asset) == id { identifier = asset.localIdentifier; stop.pointee = true }
        }
        return identifier
    }

    // MARK: - 保存
    //
    // 在单个 performChanges 事务里完成「创建资产 + 找到或新建 JustShoot 相簿 + 把资产加入相簿」，
    // 避免 PHAssetCollection / PHAsset 这类非 Sendable 对象跨 await 传递。返回新资产的
    // localIdentifier 供 SwiftData 索引。
    static func save(
        imageData: Data,
        creationDate: Date,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        locationTimestamp: Date?,
        captureID: UUID? = nil
    ) async throws -> String {
        let trace = DiagnosticTrace(id: captureID?.uuidString ?? "legacy-photo-export")
        try await ensureAuthorized(trace: trace)
        if let captureID, let existing = findCapture(id: captureID, creationDate: creationDate) { return existing }
        // 相簿创建已串行化（见 ensureAlbumIdentifier）。创建失败不阻塞照片保存——资产仍正常
        // 入库（app 内画廊走 SwiftData 索引，不依赖相簿成员关系），只是不进 JustShoot 相簿。
        let albumLookup = trace.span("photos_album_lookup")
        let albumID = try? await ensureAlbumIdentifier()
        albumLookup.end(albumID == nil ? "no_album" : "ok")

        let idBox = Box<String?>(nil)
        let albumMissingBox = Box(false)
        let transaction = trace.span("photos_transaction")
        var transactionStatus = "error"
        defer { transaction.end(transactionStatus) }
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            creation.creationDate = creationDate

            if let lat = latitude, let lon = longitude {
                creation.location = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    altitude: altitude ?? 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 10,
                    timestamp: locationTimestamp ?? creationDate
                )
            }

            let options = PHAssetResourceCreationOptions()
            // 用 CGImageSource 探测真实 UTI（HEIC/JPEG）。硬编码 "public.jpeg" 会让 HEIC 触发
            // PHPhotosErrorDomain 3302（data 与声明 UTI 不一致）。
            if let src = CGImageSourceCreateWithData(imageData as CFData, nil),
               let uti = CGImageSourceGetType(src) {
                options.uniformTypeIdentifier = uti as String
            }
            if let captureID { options.originalFilename = captureFilename(captureID, imageData: imageData) }
            creation.addResource(with: .photo, data: imageData, options: options)

            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            idBox.value = placeholder.localIdentifier

            addToAlbum(placeholder: placeholder, albumID: albumID, albumMissing: albumMissingBox)
        }
        if albumMissingBox.value { await invalidateAlbumCache() }

        guard let id = idBox.value else { throw PhotoLibraryError.saveFailed }
        transactionStatus = "ok"
        return id
    }

    // MARK: - 保存 Live Photo
    //
    // 与 save 同构，但在同一 PHAssetCreationRequest 上挂两个资源：.photo（已套 LUT 的 HEIC 字节）
    // + .pairedVideo（已套 LUT、写好 content identifier + still-image-time 的 .mov 文件）。Photos
    // 据两个资源里相同的 content identifier 把它们识别为一张 Live Photo。视频用 shouldMoveFile=true：
    // 保存即移动临时文件进图库，省一次拷贝，事务结束后临时文件已不在原处（caller 的 cleanup 兜底）。
    static func saveLivePhoto(
        imageData: Data,
        videoURL: URL,
        creationDate: Date,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        locationTimestamp: Date?,
        captureID: UUID? = nil,
        moveVideo: Bool = true
    ) async throws -> String {
        let trace = DiagnosticTrace(id: captureID?.uuidString ?? "legacy-photo-export")
        try await ensureAuthorized(trace: trace)
        if let captureID, let existing = findCapture(id: captureID, creationDate: creationDate) { return existing }
        let albumLookup = trace.span("photos_album_lookup")
        let albumID = try? await ensureAlbumIdentifier()
        albumLookup.end(albumID == nil ? "no_album" : "ok")

        let idBox = Box<String?>(nil)
        let albumMissingBox = Box(false)
        let transaction = trace.span("photos_transaction")
        var transactionStatus = "error"
        defer { transaction.end(transactionStatus) }
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            creation.creationDate = creationDate

            if let lat = latitude, let lon = longitude {
                creation.location = CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    altitude: altitude ?? 0,
                    horizontalAccuracy: 10,
                    verticalAccuracy: 10,
                    timestamp: locationTimestamp ?? creationDate
                )
            }

            let photoOptions = PHAssetResourceCreationOptions()
            if let src = CGImageSourceCreateWithData(imageData as CFData, nil),
               let uti = CGImageSourceGetType(src) {
                photoOptions.uniformTypeIdentifier = uti as String
            }
            if let captureID { photoOptions.originalFilename = captureFilename(captureID, imageData: imageData) }
            creation.addResource(with: .photo, data: imageData, options: photoOptions)

            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.shouldMoveFile = moveVideo
            creation.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)

            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            idBox.value = placeholder.localIdentifier

            addToAlbum(placeholder: placeholder, albumID: albumID, albumMissing: albumMissingBox)
        }
        if albumMissingBox.value { await invalidateAlbumCache() }

        guard let id = idBox.value else { throw PhotoLibraryError.saveFailed }
        transactionStatus = "ok"
        return id
    }

    /// 在 performChanges 事务内把新资产加入 JustShoot 相簿。相簿按串行化缓存的 identifier 取，
    /// 取不到（用户删了相簿）回退 findAlbum 再试；仍不在则置 albumMissing 让 caller 失效缓存——
    /// 本张照片不进相簿（资产本身已保存，不因相簿缺失丢照片）。
    private static func addToAlbum(placeholder: PHObjectPlaceholder, albumID: String?, albumMissing: Box<Bool>) {
        let album: PHAssetCollection? = {
            if let albumID,
               let fetched = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
                return fetched
            }
            return findAlbum()
        }()
        if let album, let albumChange = PHAssetCollectionChangeRequest(for: album) {
            albumChange.addAssets([placeholder] as NSArray)
        } else {
            albumMissing.value = true
        }
    }

    /// 同步查找已存在的 JustShoot 相簿（PHAssetCollection fetch 线程安全，结果不跨 await）。
    private static func findAlbum() -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title = %@", albumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    // MARK: - 相簿创建串行化
    //
    // save/saveLivePhoto 原本各自在事务内 find-or-create：并发拍摄（在途上限 live 2 / normal 3）
    // 首启连拍时两个事务都看到相簿不存在 → 各建一个同名 "JustShoot"，之后 findAlbum().firstObject
    // 取哪个不确定，相册被永久分叉。收敛成 MainActor 上共享的一个 Task：创建只发生一次，后续调用
    // 复用缓存的 localIdentifier；失败清空缓存允许重试。
    @MainActor private static var albumIdentifierTask: Task<String, any Error>?

    private static func ensureAlbumIdentifier() async throws -> String {
        let task: Task<String, any Error> = await MainActor.run {
            if let existing = albumIdentifierTask { return existing }
            let t = Task<String, any Error> {
                if let album = findAlbum() { return album.localIdentifier }
                let idBox = Box<String?>(nil)
                try await PHPhotoLibrary.shared().performChanges {
                    let creation = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                    idBox.value = creation.placeholderForCreatedAssetCollection.localIdentifier
                }
                guard let id = idBox.value else { throw PhotoLibraryError.saveFailed }
                Log.save.info("album_created id=\(id, privacy: .public)")
                return id
            }
            albumIdentifierTask = t
            return t
        }
        do {
            return try await task.value
        } catch {
            // 失败不缓存——下次保存重试创建。
            _ = await MainActor.run { albumIdentifierTask = nil }
            throw error
        }
    }

    /// 缓存的相簿 identifier 失效（用户在「照片」app 删掉了相簿）——清掉让下次保存重建。
    @MainActor private static func invalidateAlbumCache() {
        albumIdentifierTask = nil
    }

    // MARK: - 删除
    //
    // 通过 PHAssetChangeRequest.deleteAssets 删除——系统会**自动弹出**删除确认弹窗（无法抑制，
    // 也不该抑制：这是用户照片，且删除进「最近删除」可在 30 天内恢复）。用户取消 → performChanges
    // 抛错，caller 据此保留 SwiftData 索引行。fetch 放在 change block 内，避免 PHFetchResult 跨 await。
    static func delete(localIdentifiers: [String]) async throws {
        guard !localIdentifiers.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
            guard assets.count > 0 else { return }
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    // MARK: - 反向同步辅助
    //
    // 给定一批 localIdentifier，返回其中在系统相册里仍存在的子集（批量一次 fetch，同步）。
    // **仅在完整 .authorized 时工作，否则返回 nil 让 caller 跳过剪枝**：
    //   - 未授权：fetch 必空，当成「全部不存在」会误删整个索引；
    //   - .limited：fetch 不到 ≠ 已删除——用户可能只是把某些资产移出了授权选集（或 iCloud
    //     恢复尚未本地化），照片明明还在，据此剪枝会永久丢索引行。
    // PHAsset fetch 线程安全，可在后台 @ModelActor 上直接调。
    static func existingAssetIdentifiers(from ids: [String]) -> Set<String>? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        guard !ids.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var present = Set<String>()
        fetch.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        return present
    }

    // MARK: - 正向同步辅助（孤儿资产回填用）
    //
    // JustShoot 相簿内全部资产的轻量信息（identifier / 创建时间 / 是否 Live）。与剪枝同一安全
    // 前提：仅在完整 .authorized 时返回，.limited 下相簿 fetch 可能不完整、不可作为对账输入；
    // 相簿不存在返回空数组。同步 fetch，可在后台 @ModelActor 上直接调。
    static func albumAssetInfo() -> [(id: String, creationDate: Date?, isLivePhoto: Bool, captureID: UUID?)]? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        guard let album = findAlbum() else { return [] }
        let fetch = PHAsset.fetchAssets(in: album, options: nil)
        var result: [(id: String, creationDate: Date?, isLivePhoto: Bool, captureID: UUID?)] = []
        fetch.enumerateObjects { asset, _, _ in
            result.append((asset.localIdentifier, asset.creationDate, asset.mediaSubtypes.contains(.photoLive), captureIdentifier(of: asset)))
        }
        return result
    }
}

// MARK: - 反向同步观察者（library → app）
//
// 系统相册发生变化（用户在「照片」app 删图等）时，剪掉指向已删资产的本地索引行。架构（见调研）：
// 不做 changeDetails 差分 / 不用 persistent change token——统一调一个幂等的 `pruneDeletedAssets()`
// reconcile，足够简单且总是正确，适配个人相册规模。两个触发点：
//   1. 冷同步：进画廊时 GalleryView.task 调一次（覆盖「app 关闭期间被删」的情况）。
//   2. 实时：本观察者在启动时注册，app 前台时系统相册一变就 reconcile（去重 400ms）。
// 规模化升级路径（如需）：改用 PHPhotoLibrary.fetchPersistentChanges(since:) 的 deletedLocalIdentifiers
// 增量，省去全量扫描；当前规模不需要。
@MainActor
final class PhotoLibrarySync: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoLibrarySync()
    private var container: ModelContainer?
    private var registered = false
    private var reconcileTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private var didMaintain = false

    func start(container: ModelContainer) {
        self.container = container
        guard !registered, PhotoLibrary.isAuthorized else { return }
        PHPhotoLibrary.shared().register(self)
        registered = true
    }

    func bootstrap(container: ModelContainer) async {
        start(container: container)
        guard !didMaintain else { return }
        didMaintain = true
        let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
        await saver.performLaunchMaintenance()
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            self.needsAnotherPass = true
            await self.reconcile()
        }
    }

    func reconcile() async {
        if let container { start(container: container) }
        if let reconcileTask { await reconcileTask.value; return }
        guard let container else { return }
        let task = Task {
            let reconciliation = DiagnosticTrace(id: "library-sync").span("library_reconcile")
            defer { reconciliation.end() }
            let saver = await Task.detached { PhotoSaver(modelContainer: container) }.value
            repeat {
                self.needsAnotherPass = false
                try? await Task.sleep(for: .milliseconds(400))
                await saver.reconcileWithLibrary()
            } while self.needsAnotherPass
            NotificationCenter.default.post(name: .photoLibraryDidReconcile, object: nil)
        }
        reconcileTask = task
        await task.value
        reconcileTask = nil
        if needsAnotherPass { await reconcile() }
    }

}

extension Notification.Name {
    /// PhotoLibrarySync 完成一轮 reconcile（剪枝已删资产的索引行）后发出。
    static let photoLibraryDidReconcile = Notification.Name("photoLibraryDidReconcile")
}

// MARK: - 资产图片加载器（PHCachingImageManager 包装）

/// PhotoKit can call back before returning a request ID; cancellation can race either event.
/// Resume once, outside the lock, and cancel a late request ID if the Swift task already ended.
typealias PhotoImageRequestState = PhotoRequestState<UIImage>

final class PhotoRequestState<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value?, Never>?
        var requestID = PHInvalidImageRequestID
        var finished = false
        var cancelled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isFinished: Bool { state.withLock { $0.finished } }

    func install(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        let installed = state.withLock {
            guard !$0.finished else { return false }
            $0.continuation = continuation
            return true
        }
        if !installed { continuation.resume(returning: nil) }
        return installed
    }

    /// Returns true when the caller must cancel this ID immediately.
    func register(_ requestID: PHImageRequestID) -> Bool {
        state.withLock {
            guard !$0.finished else { return $0.cancelled }
            $0.requestID = requestID
            return false
        }
    }

    @discardableResult
    func finish(_ value: Value?) -> Bool {
        let result = state.withLock { state -> (Bool, CheckedContinuation<Value?, Never>?) in
            guard !state.finished else { return (false, nil) }
            state.finished = true
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        result.1?.resume(returning: value)
        return result.0
    }

    func cancel() -> (didFinish: Bool, requestID: PHImageRequestID) {
        let result = state.withLock { state -> (Bool, PHImageRequestID, CheckedContinuation<Value?, Never>?) in
            guard !state.finished else { return (false, PHInvalidImageRequestID, nil) }
            state.finished = true
            state.cancelled = true
            let continuation = state.continuation
            state.continuation = nil
            return (true, state.requestID, continuation)
        }
        result.2?.resume(returning: nil)
        return (result.0, result.1)
    }
}
//
// 取代针对内部 blob 的自建解码/磁盘缓存：PHImageManager 自带按尺寸缓存 + iCloud 回源 +
// opportunistic（先糊后清）渐进交付。这里加一层小 NSCache 仅为「同步首帧探测」（cell 复用时
// 零延迟出图），避免 SwiftUI/UIKit 启动一帧的黑屏。
final class AssetImageLoader: @unchecked Sendable {
    static let shared = AssetImageLoader()
    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 120
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

    /// 同步查内存缓存（不发起请求）。命中即零延迟。
    func cachedThumbnail(id: String, maxPixel: Int) -> UIImage? {
        cache.object(forKey: "\(id)_\(maxPixel)" as NSString)
    }

    /// UIKit cell 用：opportunistic 渐进交付（先糊后清），completion 可能被多次回调（PHImageManager
    /// 在主线程回调）。返回 PHImageRequestID 供 cell 复用时 cancel。
    @discardableResult
    func requestThumbnail(id: String, maxPixel: Int, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        guard let asset = asset(id: id) else { completion(nil); return PHInvalidImageRequestID }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        let size = CGSize(width: maxPixel, height: maxPixel)
        let key = "\(id)_\(maxPixel)" as NSString
        return manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: opts) { [weak self] image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if let image, !degraded, let self {
                self.cache.setObject(image, forKey: key, cost: self.cost(image))
            }
            completion(image)
        }
    }

    func cancel(_ requestID: PHImageRequestID) {
        guard requestID != PHInvalidImageRequestID else { return }
        manager.cancelImageRequest(requestID)
    }

    /// async 单发缩略图（取最终高质量版本一次返回）。aspectFill 方形。
    func thumbnail(id: String, maxPixel: Int, trace: DiagnosticTrace? = nil) async -> UIImage? {
        if let cached = cachedThumbnail(id: id, maxPixel: maxPixel) { return cached }
        let img = await requestImage(id: id, targetSize: CGSize(width: maxPixel, height: maxPixel),
                                     contentMode: .aspectFill, resize: .fast, trace: trace, kind: "thumbnail")
        if let img { cache.setObject(img, forKey: "\(id)_\(maxPixel)" as NSString, cost: cost(img)) }
        return img
    }

    /// async 单发大图预览。aspectFit + exact 精确缩放。
    func preview(id: String, maxPixel: Int, trace: DiagnosticTrace? = nil) async -> UIImage? {
        await requestImage(id: id, targetSize: CGSize(width: maxPixel, height: maxPixel),
                           contentMode: .aspectFit, resize: .exact, trace: trace, kind: "preview")
    }

    private func requestImage(id: String, targetSize: CGSize, contentMode: PHImageContentMode,
                              resize: PHImageRequestOptionsResizeMode, trace: DiagnosticTrace?, kind: String) async -> UIImage? {
        let request = trace?.span("photo_asset_request", "kind=\(kind) max_pixel=\(Int(max(targetSize.width, targetSize.height)))")
        guard !Task.isCancelled else { request?.end("cancelled"); return nil }
        guard let asset = asset(id: id) else {
            request?.end("missing_asset", "authorization=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
            return nil
        }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.resizeMode = resize
        opts.isNetworkAccessAllowed = true
        return await performRequest(span: request) { handler in
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: opts, resultHandler: handler)
        }
    }

    private func performRequest<Value: Sendable>(span: DiagnosticSpan?,
        start: (@escaping (Value?, [AnyHashable: Any]?) -> Void) -> PHImageRequestID) async -> Value? {
        let state = PhotoRequestState<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard state.install(continuation) else { return }
                let requestID = start { value, info in
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    let error = info?[PHImageErrorKey] as? NSError
                    if !cancelled, error == nil, (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
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
    func imageData(id: String, trace: DiagnosticTrace? = nil) async -> Data? {
        let request = trace?.span("photo_asset_request", "kind=original")
        guard !Task.isCancelled else { request?.end("cancelled"); return nil }
        guard let asset = asset(id: id) else { request?.end("missing_asset"); return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return await performRequest(span: request) { handler in
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
}

// MARK: - 统一取图门面
//
// 调用点（grid cell / detail pager / scrubber / info 面板）只跟它打交道：有 assetLocalIdentifier
// 走系统相册，否则回退到遗留内部 blob（ImageLoader）。读取 Photo 属性发生在 @MainActor，提取后
// 才进入 PhotoKit 异步路径。
enum PhotoImage {
    @MainActor
    static func thumbnail(for photo: Photo, maxPixel: Int, trace: DiagnosticTrace? = nil) async -> UIImage? {
        guard !Task.isCancelled, !photo.isDeleted else { return nil }
        if let aid = photo.assetLocalIdentifier {
            return await AssetImageLoader.shared.thumbnail(id: aid, maxPixel: maxPixel, trace: trace)
        }
        if let data = photo.imageData {
            return await ImageLoader.shared.loadThumbnail(imageData: data, photoId: photo.id, maxPixel: maxPixel)
        }
        return nil
    }

    @MainActor
    static func preview(for photo: Photo, maxPixel: Int, trace: DiagnosticTrace? = nil) async -> UIImage? {
        guard !Task.isCancelled, !photo.isDeleted else { return nil }
        if let aid = photo.assetLocalIdentifier {
            return await AssetImageLoader.shared.preview(id: aid, maxPixel: maxPixel, trace: trace)
        }
        if let data = photo.imageData {
            return await ImageLoader.shared.loadPreview(imageData: data, photoId: photo.id, maxPixel: maxPixel)
        }
        return nil
    }

    @MainActor
    static func exifData(for photo: Photo) async -> Data? {
        guard !Task.isCancelled, !photo.isDeleted else { return nil }
        let trace = DiagnosticTrace(id: photo.id.uuidString)
        if let aid = photo.assetLocalIdentifier {
            return await AssetImageLoader.shared.imageData(id: aid, trace: trace)
        }
        return photo.imageData
    }
}
