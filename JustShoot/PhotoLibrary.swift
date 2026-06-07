import Photos
import UIKit
import SwiftData
import CoreLocation
import ImageIO

// MARK: - 系统相册为真相源（Photos library is the source of truth）
//
// 架构：拍摄的成品照片直接写入系统相册的 "JustShoot" 自定义相簿，SwiftData 只保留轻量索引
// （PHAsset.localIdentifier + 胶片元数据）。好处：照片真正进用户图库、白拿 iCloud 同步/备份、
// 卸载不丢、滚动缩略图走系统级 PHCachingImageManager。app 内画廊 = 基于这些 identifier 的策展层。
//
// 兼容/兜底：拍摄时若相册写入失败（权限拒绝），把字节暂存进 Photo.imageData，待授权后由
// PhotoMigrator 迁入相册；旧版本遗留的内部照片同样由 PhotoMigrator 在首次授权后迁移。

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
    static func ensureAuthorized() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status: PHAuthorizationStatus = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            : current
        guard status == .authorized || status == .limited else {
            throw PhotoLibraryError.notAuthorized
        }
    }

    static var isAuthorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
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
        locationTimestamp: Date?
    ) async throws -> String {
        try await ensureAuthorized()

        let idBox = Box<String?>(nil)
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
            creation.addResource(with: .photo, data: imageData, options: options)

            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            idBox.value = placeholder.localIdentifier

            // 找到或在同一事务内新建 JustShoot 相簿，并把新资产加入。
            if let album = findAlbum(),
               let albumChange = PHAssetCollectionChangeRequest(for: album) {
                albumChange.addAssets([placeholder] as NSArray)
            } else {
                let albumCreation = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                albumCreation.addAssets([placeholder] as NSArray)
            }
        }

        guard let id = idBox.value else { throw PhotoLibraryError.saveFailed }
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
        locationTimestamp: Date?
    ) async throws -> String {
        try await ensureAuthorized()

        let idBox = Box<String?>(nil)
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
            creation.addResource(with: .photo, data: imageData, options: photoOptions)

            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.shouldMoveFile = true
            creation.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)

            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            idBox.value = placeholder.localIdentifier

            if let album = findAlbum(),
               let albumChange = PHAssetCollectionChangeRequest(for: album) {
                albumChange.addAssets([placeholder] as NSArray)
            } else {
                let albumCreation = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                albumCreation.addAssets([placeholder] as NSArray)
            }
        }

        guard let id = idBox.value else { throw PhotoLibraryError.saveFailed }
        return id
    }

    /// 同步查找已存在的 JustShoot 相簿（仅在 performChanges 闭包内调用，结果不跨 await）。
    private static func findAlbum() -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title = %@", albumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
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
    // **未授权时返回 nil**——此时 fetch 必空，若当成「全部不存在」会误删整个索引；返回 nil 让
    // caller 跳过剪枝。PHAsset fetch 线程安全，可在后台 @ModelActor 上直接调。
    static func existingAssetIdentifiers(from ids: [String]) -> Set<String>? {
        guard isAuthorized else { return nil }
        guard !ids.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var present = Set<String>()
        fetch.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        return present
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
    private var reconcilePending = false

    /// app 启动时调一次。注册观察者本身不需要相册权限（剪枝逻辑内部再按授权状态 gate），
    /// 所以无条件注册即可——授权后产生的变更会自然回调进来。
    func start(container: ModelContainer) {
        self.container = container
        guard !registered else { return }
        PHPhotoLibrary.shared().register(self)
        registered = true
    }

    // 回调在 PhotoKit 的后台串行队列——回主 actor 调度去重，再把 reconcile 派到后台 @ModelActor。
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in self.scheduleReconcile() }
    }

    private func scheduleReconcile() {
        guard let container, !reconcilePending else { return }
        reconcilePending = true
        Task { @MainActor in
            // 合并连续变更（一次批量删除可能触发多次回调）。
            try? await Task.sleep(for: .milliseconds(400))
            reconcilePending = false
            await PhotoSaver(modelContainer: container).pruneDeletedAssets()
        }
    }
}

// MARK: - 资产图片加载器（PHCachingImageManager 包装）
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
    func thumbnail(id: String, maxPixel: Int) async -> UIImage? {
        let img = await requestImage(id: id, targetSize: CGSize(width: maxPixel, height: maxPixel),
                                     contentMode: .aspectFill, resize: .fast)
        if let img { cache.setObject(img, forKey: "\(id)_\(maxPixel)" as NSString, cost: cost(img)) }
        return img
    }

    /// async 单发大图预览。aspectFit + exact 精确缩放。
    func preview(id: String, maxPixel: Int) async -> UIImage? {
        await requestImage(id: id, targetSize: CGSize(width: maxPixel, height: maxPixel),
                           contentMode: .aspectFit, resize: .exact)
    }

    private func requestImage(id: String, targetSize: CGSize, contentMode: PHImageContentMode, resize: PHImageRequestOptionsResizeMode) async -> UIImage? {
        guard let asset = asset(id: id) else { return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat   // 单次回调，可安全 resume continuation 一次
        opts.resizeMode = resize
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let resumed = Box(false)
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: opts) { image, _ in
                if resumed.value { return }
                resumed.value = true
                cont.resume(returning: image)
            }
        }
    }

    /// 加载 PHLivePhoto（详情页长按播放用）。targetSize 给屏幕尺寸即可；PHImageManager 自带缓存 +
    /// iCloud 回源。highQualityFormat 单次回调，可安全 resume 一次。
    func livePhoto(id: String, targetSize: CGSize) async -> PHLivePhoto? {
        guard let asset = asset(id: id) else { return nil }
        let opts = PHLivePhotoRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (cont: CheckedContinuation<PHLivePhoto?, Never>) in
            let resumed = Box(false)
            manager.requestLivePhoto(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: opts) { livePhoto, info in
                // opportunistic 可能多次回调；highQualityFormat 理论一次，但仍以 Box 守护只 resume 一次。
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded && livePhoto == nil { return }
                if resumed.value { return }
                resumed.value = true
                cont.resume(returning: livePhoto)
            }
        }
    }

    /// 原始字节（用于 EXIF 解析）。
    func imageData(id: String) async -> Data? {
        guard let asset = asset(id: id) else { return nil }
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            let resumed = Box(false)
            manager.requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, _ in
                if resumed.value { return }
                resumed.value = true
                cont.resume(returning: data)
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
    static func thumbnail(for photo: Photo, maxPixel: Int) async -> UIImage? {
        if let aid = photo.assetLocalIdentifier {
            return await AssetImageLoader.shared.thumbnail(id: aid, maxPixel: maxPixel)
        }
        if let data = photo.imageData {
            return await ImageLoader.shared.loadThumbnail(imageData: data, photoId: photo.id, maxPixel: maxPixel)
        }
        return nil
    }

    @MainActor
    static func preview(for photo: Photo, maxPixel: Int) async -> UIImage? {
        if let aid = photo.assetLocalIdentifier {
            return await AssetImageLoader.shared.preview(id: aid, maxPixel: maxPixel)
        }
        if let data = photo.imageData {
            return await ImageLoader.shared.loadPreview(imageData: data, photoId: photo.id, maxPixel: maxPixel)
        }
        return nil
    }

    @MainActor
    static func exifData(for photo: Photo) async -> Data? {
        if let aid = photo.assetLocalIdentifier {
            return await AssetImageLoader.shared.imageData(id: aid)
        }
        return photo.imageData
    }
}
