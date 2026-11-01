import Photos
import UIKit
import SwiftData
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import os

// MARK: - 系统相册为真相源（Photos library is the source of truth）
//
// 架构：拍摄的成品照片直接写入系统相册的 "JustShoot" 自定义相簿，SwiftData 只保留轻量索引
// （PHAsset.localIdentifier + 胶片元数据）。好处：照片真正进用户图库、白拿 iCloud 同步/备份、
// 卸载不丢、滚动缩略图走系统级 PHCachingImageManager。app 内画廊 = 基于这些 identifier 的策展层。
//
// 兼容/兜底：拍摄时若相册写入失败（权限拒绝），把字节暂存进 Photo.imageData，待授权后由
// PhotoLibraryReconciler.migrateInternalPhotos（reconcileWithLibrary 的第一步）迁入相册；旧版本遗留的
// 内部照片同样经它在首次授权后迁移，迁入后 blob 置 nil 释放 externalStorage。

/// 把可变值塞进 @Sendable performChanges 闭包用的轻量盒子（PhotoKit 的 change block 在
/// Swift 6 strict concurrency 下是 @Sendable，无法直接捕获并回写局部 var）。
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

enum PhotoLibraryError: LocalizedError, Equatable {
    case notAuthorized
    case saveFailed
    case inaccessibleAssets

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            String(localized: "Allow Photos access in Settings to save or delete photos.")
        case .saveFailed:
            String(localized: "The photo could not be saved. Please try again.")
        case .inaccessibleAssets:
            String(localized: "Some photos are not accessible. Allow access to those photos in Settings before deleting them.")
        }
    }
}

/// Missing assets imply deletion only when the whole library is visible.
enum PhotoDeletionPolicy {
    static func failure(authorization: PHAuthorizationStatus, requestedCount: Int,
                        accessibleCount: Int) -> PhotoLibraryError? {
        guard authorization == .authorized || authorization == .limited else { return .notAuthorized }
        if authorization == .limited && accessibleCount != requestedCount { return .inaccessibleAssets }
        return nil
    }
}

enum PhotoLibrary {
    static let albumTitle = "JustShoot"

    // MARK: - 授权（读写）
    //
    // 真相源在相册，所以需要 .readWrite（写入 + 回读资产）。.limited 下新建资产会加入可见选集；
    // 读取不到已有资产时不能据此判定它已被删除。仅在 .notDetermined 时弹一次系统授权。
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
        for resource in PHAssetResource.assetResources(for: asset) where resource.type == .photo || resource.type == .photoProxy {
            let filename: String
            if #available(iOS 27, *) { filename = resource.filename ?? "" }
            else { filename = resource.originalFilename }
            guard filename.hasPrefix("JustShoot_") else { continue }
            let stem = (filename as NSString).deletingPathExtension
            return UUID(uuidString: String(stem.dropFirst("JustShoot_".count)))
        }
        return nil
    }

    /// An older backfilled row may have a different UUID from its durable capture job.
    static func captureIdentifiers(from localIdentifiers: [String]) -> Set<UUID> {
        guard isAuthorized, !localIdentifiers.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        var ids: Set<UUID> = []
        assets.enumerateObjects { asset, _, _ in
            if let id = captureIdentifier(of: asset) { ids.insert(id) }
        }
        return ids
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

    /// Persist the proxy immediately; PhotoKit owns the intermediate capture resources
    /// needed to produce the real 24 MP photo. Do not decode or filter proxy pixels.
    static func saveDeferredProxy(_ data: Data, recipe: CaptureRecipe) async throws -> String {
        try await ensureAuthorized()
        if let existing = findCapture(id: recipe.id, creationDate: recipe.captureDate) { return existing }
        let result = Box<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            creation.creationDate = recipe.captureDate
            creation.location = recipe.location?.location
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = captureFilename(recipe.id, imageData: data)
            creation.addResource(with: .photoProxy, data: data, options: options)
            result.value = creation.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = result.value else { throw PhotoLibraryError.saveFailed }
        return id
    }

    static func finalizedDeferredPhoto(id: String, expected: DeferredPhotoState) async throws -> Data {
        try await ensureAuthorized()
        let data = await AssetImageLoader.shared.imageData(id: id, original: true, timeout: 120)
        try Task.checkCancellation()
        guard let data, expected.acceptsFinalImage(data) else { throw PhotoLibraryError.saveFailed }
        return data
    }

    /// Commit the film as an adjustment to the original asset, retaining Apple's
    /// finalized original and publishing a single photo in the JustShoot album.
    static func prepareDeferredAdjustment(id: String) async throws -> DeferredEditingInput {
        try await ensureAuthorized()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoLibraryError.inaccessibleAssets
        }
        return DeferredEditingInput(value: try await DeferredPhotoEditingRequest.input(for: asset))
    }

    static func saveDeferredAdjustment(imageData: Data, id: String, recipe: CaptureRecipe,
                                       preparedInput: DeferredEditingInput? = nil) async throws {
        let input: PHContentEditingInput
        if let preparedInput { input = preparedInput.value }
        else { input = try await prepareDeferredAdjustment(id: id).value }
        let output = PHContentEditingOutput(contentEditingInput: input)
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
              output.supportedRenderedContentTypes.contains(type) else { throw PhotoLibraryError.saveFailed }
        let url = try output.renderedContentURL(for: type)
        try imageData.write(to: url, options: .atomic)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.justshoot.film", formatVersion: "1",
            data: try JSONEncoder().encode(recipe))
        let editingOutput = Box(output)
        let albumID = try? await ensureAlbumIdentifier()
        let albumMissing = Box(false)
        let saved = Box(false)
        try Task.checkCancellation()
        try await PHPhotoLibrary.shared().performChanges {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return }
            let change = PHAssetChangeRequest(for: asset)
            change.contentEditingOutput = editingOutput.value
            change.creationDate = recipe.captureDate
            change.location = recipe.location?.location
            if let albumID,
               let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
               let albumChange = PHAssetCollectionChangeRequest(for: album) {
                albumChange.addAssets([asset] as NSArray)
            } else { albumMissing.value = true }
            saved.value = true
        }
        if albumMissing.value { await invalidateAlbumCache() }
        guard saved.value else { throw PhotoLibraryError.saveFailed }
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
            let t = Task<String, any Error>.detached(priority: .utility) {
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
        let identifiers = Array(Set(localIdentifiers))
        // Reject inaccessible batches before opening a system deletion confirmation.
        if let failure = PhotoDeletionPolicy.failure(
            authorization: PHPhotoLibrary.authorizationStatus(for: .readWrite),
            requestedCount: identifiers.count,
            accessibleCount: PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).count
        ) { throw failure }

        let failureBox = Box<PhotoLibraryError?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            // Authorization or selection can change between preflight and the transaction.
            failureBox.value = PhotoDeletionPolicy.failure(
                authorization: PHPhotoLibrary.authorizationStatus(for: .readWrite),
                requestedCount: identifiers.count, accessibleCount: assets.count)
            guard failureBox.value == nil else { return }
            guard assets.count > 0 else { return }
            PHAssetChangeRequest.deleteAssets(assets)
        }
        if let failure = failureBox.value { throw failure }
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
