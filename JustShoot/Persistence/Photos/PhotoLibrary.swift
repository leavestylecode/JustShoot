import Photos
import UIKit
import SwiftData
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import os

// MARK: - 系统相册为真相源（Photos library is the source of truth）
//
// 架构：拍摄的成品照片直接写入系统相册的自定义相簿，SwiftData 只保留轻量索引
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
    private static let albumTitle = "OOO"
    private static let legacyAlbumTitle = "JustShoot"
    private static let legacyCaptureFilenamePrefix = "JustShoot_"

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

    private static func imageOptions(data: Data, stem: String?, isProxy: Bool = false) -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let type = source.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
        if !isProxy, let type {
            if #available(iOS 26, *) { options.contentType = type }
            else { options.uniformTypeIdentifier = type.identifier }
        }
        // An opaque deferred proxy develops into the camera's HEIC original.
        let ext = type?.preferredFilenameExtension ?? (isProxy ? "heic" : nil)
        if let stem, let ext { options.originalFilename = "\(stem).\(CaptureFilename.normalizedExtension(ext))" }
        return options
    }

    static func navigationURL(for assetID: String) -> URL? {
        // Older Photos versions can show an empty filename search even for a local asset.
        if #unavailable(iOS 18), let asset = AssetImageLoader.shared.asset(id: assetID) {
            let collections = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
            for index in 0..<collections.count {
                let album = collections.object(at: index)
                if album.localizedTitle == albumTitle || album.localizedTitle == legacyAlbumTitle,
                   let url = albumURL(albumID: album.localIdentifier, assetID: assetID) {
                    return url
                }
            }
        }
        return stillFilename(id: assetID).flatMap(searchURL(filename:))
    }

    static func albumURL(albumID: String, assetID: String) -> URL? {
        // PhotoKit identifiers currently start with a UUID. Fall back to a filename
        // search if Photos supplies an identifier in a different format.
        guard let album = albumID.split(separator: "/").first.flatMap({ UUID(uuidString: String($0)) }),
              let asset = assetID.split(separator: "/").first.flatMap({ UUID(uuidString: String($0)) }) else { return nil }
        var url = URLComponents()
        url.scheme = "photos-navigation"
        url.host = "album"
        url.queryItems = [URLQueryItem(name: "uuid", value: album.uuidString),
                          URLQueryItem(name: "revealassetuuid", value: asset.uuidString)]
        return url.url
    }

    static func searchURL(filename: String) -> URL? {
        let stem = (filename as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
        var url = URLComponents()
        url.scheme = "photos-navigation"
        url.host = "search"
        url.queryItems = [URLQueryItem(name: "searchTerm", value: stem)]
        return url.url
    }

    /// Read the actual current file. PHImageManager can supply a resized/re-encoded
    /// display derivative that has the right pixels but fewer EXIF fields after an edit.
    static func currentFileInfo(id: String) async throws -> (exif: ParsedExifInfo, bytes: Int64?, adjustment: PhotoLookAdjustment?) {
        guard let asset = AssetImageLoader.shared.asset(id: id) else { throw PhotoEditError.unavailable }
        let adjustment = OSAllocatedUnfairLock(initialState: Optional<PhotoLookAdjustment>.none)
        let input = try await DeferredPhotoEditingRequest.input(for: asset) { data in
            let look = PhotoEditSession.lookAdjustment(data)
            adjustment.withLock { $0 = look }
            return false // Ask for current rendered EXIF even when we recognize the recipe.
        }
        guard let url = input.fullSizeImageURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoEditError.render
        }
        let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return (ParsedExifInfo.parse(from: source), bytes.map(Int64.init), adjustment.withLock { $0 })
    }

    static func stillFilename(id: String) -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resource = PHAssetResource.assetResources(for: asset).first(where: {
                  $0.type == .photo || $0.type == .photoProxy
              }) else { return nil }
        if #available(iOS 27, *) { return resource.filename }
        return resource.originalFilename
    }

    static func captureIdentifier(of asset: PHAsset) -> UUID? {
        let filenames = PHAssetResource.assetResources(for: asset).lazy
            .filter { $0.type == .photo || $0.type == .photoProxy }
            .compactMap { resource -> String? in
                if #available(iOS 27, *) { return resource.filename }
                return resource.originalFilename
            }
        return captureIdentifier(in: filenames)
    }

    static func captureIdentifier(in filenames: some Sequence<String>) -> UUID? {
        for filename in filenames {
            guard let prefix = [CaptureFilename.prefix, legacyCaptureFilenamePrefix].first(where: { filename.hasPrefix($0) }) else {
                continue
            }
            let stem = (filename as NSString).deletingPathExtension
            if let id = UUID(uuidString: String(stem.dropFirst(prefix.count))) { return id }
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
    // 同一个 performChanges 事务创建资产并加入相簿。跨 await 只传递 localIdentifier。
    static func save(
        imageData: Data,
        creationDate: Date,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        locationTimestamp: Date?,
        captureID: UUID? = nil,
        fileNumber: Int? = nil,
        journal: CaptureJournal? = nil,
        pairedVideo: URL? = nil
    ) async throws -> String {
        let trace = DiagnosticTrace(id: captureID?.uuidString ?? "legacy-photo-export")
        try await ensureAuthorized(trace: trace)
        let receipt = try captureID.flatMap { try journal?.assetPlaceholder(for: $0) }
        if let existing = try existingCapture(receipt: receipt, legacyID: fileNumber == nil ? captureID : nil,
                                              creationDate: creationDate) { return existing }
        let albumLookup = trace.span("photos_album_lookup")
        let albumID = try? await ensureAlbumIdentifier()
        albumLookup.end(albumID == nil ? "no_album" : "ok")

        let transaction = trace.span("photos_transaction")
        var status = "error"
        defer { transaction.end(status) }
        let stem = CaptureFilename.stem(id: captureID, number: fileNumber)
        let albumMissing = Box(false)
        let id = try await createAsset(recordPlaceholder: { identifier in
            if let journal, let captureID { try journal.recordAssetPlaceholder(identifier, for: captureID) }
        }) { creation, placeholder in
            creation.creationDate = creationDate
            if let latitude, let longitude {
                creation.location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    altitude: altitude ?? 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                    timestamp: locationTimestamp ?? creationDate)
            }
            creation.addResource(with: .photo, data: imageData, options: imageOptions(data: imageData, stem: stem))
            if let pairedVideo {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = stem.map { $0 + ".MOV" }
                // The journal retains the movie until the index also commits.
                creation.addResource(with: .pairedVideo, fileURL: pairedVideo, options: options)
            }
            addToAlbum(placeholder: placeholder, albumID: albumID, albumMissing: albumMissing)
        }
        if albumMissing.value { await invalidateAlbumCache(matching: albumID) }
        status = "ok"
        return id
    }

    /// Persist the proxy immediately; PhotoKit owns the intermediate capture resources
    /// needed to produce the real 24 MP photo. Do not decode or filter proxy pixels.
    static func saveDeferredProxy(_ data: Data, recipe: CaptureRecipe, reservedAsset: String? = nil,
                                  recordPlaceholder: @escaping @Sendable (String?) throws -> Void = { _ in }) async throws -> String {
        try await ensureAuthorized()
        if let existing = try existingCapture(receipt: reservedAsset, legacyID: recipe.fileNumber == nil ? recipe.id : nil,
                                              creationDate: recipe.captureDate) { return existing }
        let stem = CaptureFilename.stem(id: recipe.id, number: recipe.fileNumber)
        return try await createAsset(recordPlaceholder: recordPlaceholder) { creation, _ in
            creation.creationDate = recipe.captureDate
            creation.location = recipe.location?.location
            creation.addResource(with: .photoProxy, data: data, options: imageOptions(data: data, stem: stem, isProxy: true))
        }
    }

    private static func existingCapture(receipt: String?, legacyID: UUID?, creationDate: Date) throws -> String? {
        if let receipt {
            if PHAsset.fetchAssets(withLocalIdentifiers: [receipt], options: nil).firstObject != nil { return receipt }
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited { throw PhotoLibraryError.inaccessibleAssets }
        }
        return legacyID.flatMap { findCapture(id: $0, creationDate: creationDate) }
    }

    /// A receipt survives a process exit between the Photos commit and the SwiftData save.
    private static func createAsset(recordPlaceholder: @escaping @Sendable (String?) throws -> Void,
                                    configure: @escaping @Sendable (PHAssetCreationRequest, PHObjectPlaceholder) -> Void) async throws -> String {
        let result = Box<String?>(nil)
        let recordingFailure = Box<(any Error)?>(nil)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let creation = PHAssetCreationRequest.forAsset()
                guard let placeholder = creation.placeholderForCreatedAsset else { return }
                do { try recordPlaceholder(placeholder.localIdentifier) }
                catch { recordingFailure.value = error; return }
                result.value = placeholder.localIdentifier
                configure(creation, placeholder)
            }
        } catch {
            if result.value != nil { try recordPlaceholder(nil) }
            throw recordingFailure.value ?? error
        }
        if let error = recordingFailure.value { throw error }
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
    /// finalized original and publishing a single photo in the app's album.
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
            if let albumChange = albumChangeRequest(for: albumID, albumMissing: albumMissing) {
                albumChange.addAssets([asset] as NSArray)
            }
            saved.value = true
        }
        if albumMissing.value { await invalidateAlbumCache(matching: albumID) }
        guard saved.value else { throw PhotoLibraryError.saveFailed }
    }

    /// 在 performChanges 事务内把新资产加入相簿。相簿不可用时只保存照片。
    private static func addToAlbum(placeholder: PHObjectPlaceholder, albumID: String?, albumMissing: Box<Bool>) {
        albumChangeRequest(for: albumID, albumMissing: albumMissing)?.addAssets([placeholder] as NSArray)
    }

    private static func albumChangeRequest(for albumID: String?, albumMissing: Box<Bool>) -> PHAssetCollectionChangeRequest? {
        if let albumID {
            if let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
               let change = PHAssetCollectionChangeRequest(for: album) {
                return change
            }
            albumMissing.value = true
        }
        guard let album = findAlbum(titled: albumTitle) ?? findAlbum(titled: legacyAlbumTitle) else { return nil }
        return PHAssetCollectionChangeRequest(for: album)
    }

    private static func findAlbum(titled title: String) -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title = %@", title)
        opts.fetchLimit = 1
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: opts).firstObject
    }

    // MARK: - 相簿准备

    // 并发拍摄共享一次相簿查找、更名或创建，并缓存结果的 localIdentifier。
    @MainActor private static var albumIdentifierTask: Task<String, any Error>?

    private static func ensureAlbumIdentifier() async throws -> String {
        let task: Task<String, any Error> = await MainActor.run {
            if let existing = albumIdentifierTask { return existing }
            let t = Task<String, any Error>.detached(priority: .utility) {
                if let album = findAlbum(titled: albumTitle) { return album.localIdentifier }
                if let legacyID = findAlbum(titled: legacyAlbumTitle)?.localIdentifier {
                    await renameLegacyAlbum(id: legacyID)
                    return legacyID
                }
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
            await MainActor.run {
                if albumIdentifierTask == task { albumIdentifierTask = nil }
            }
            throw error
        }
    }

    private static func renameLegacyAlbum(id: String) async {
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
                      album.localizedTitle == legacyAlbumTitle,
                      album.canPerform(.rename),
                      let change = PHAssetCollectionChangeRequest(for: album) else { return }
                change.title = albumTitle
            }
        } catch {
            // 保存仍复用同一相簿，避免因更名失败而分叉。
            Log.save.error("album_rename_failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 缓存的相簿 identifier 失效（用户在「照片」app 删掉了相簿）——清掉让下次保存重建。
    @MainActor private static func invalidateAlbumCache(matching albumID: String?) async {
        guard let albumID, let task = albumIdentifierTask,
              (try? await task.value) == albumID, albumIdentifierTask == task else { return }
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
    // 新旧相簿内资产的轻量信息（identifier / 创建时间 / 是否 Live）。与剪枝同一安全
    // 前提：仅在完整 .authorized 时返回，.limited 下相簿 fetch 可能不完整、不可作为对账输入；
    // 相簿不存在返回空数组。同步 fetch，可在后台 @ModelActor 上直接调。
    static func albumAssetSnapshots() -> [PHFetchResult<PHAsset>]? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return nil }
        // 先查旧相簿。若并发更名发生在两次查询之间，同一个相簿仍至少可见一次。
        return [legacyAlbumTitle, albumTitle].compactMap { title in
            guard let album = findAlbum(titled: title) else { return nil }
            return PHAsset.fetchAssets(in: album, options: nil)
        }
    }
}
