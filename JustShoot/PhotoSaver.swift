import Foundation
import SwiftData

// MARK: - 后台保存 actor
//
// 把 Photo 插入 + context.save() 从主线程移走。connect 到同一个 ModelContainer 后，
// SwiftData 会把 actor 内的写入广播到主 context 的 @Query —— gallery / 计数 UI 自动刷新。
//
// @ModelActor 有独立 context，但 executor 与创建 context 的位置有关。主线程调用点统一
// 通过 background(container:) 创建，确保持久化与磁盘清理不会绑定主线程。
@ModelActor
actor PhotoSaver {
    nonisolated static func background(container: ModelContainer) async -> PhotoSaver {
        await Task.detached(priority: .utility) { PhotoSaver(modelContainer: container) }.value
    }

    /// 返回新 photo 的 id；失败抛错由 caller 报给 UI。
    func save(
        id: UUID = UUID(),
        captureDate: Date = Date(),
        assetLocalIdentifier: String?,
        imageData: Data?,
        filmPresetName: String,
        filmDisplayLabel: String?,
        isLivePhoto: Bool = false,
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        locationTimestamp: Date?
    ) throws -> UUID {
        var descriptor: FetchDescriptor<Photo>
        if let assetLocalIdentifier {
            descriptor = FetchDescriptor(predicate: #Predicate<Photo> {
                $0.id == id || $0.assetLocalIdentifier == assetLocalIdentifier
            })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate<Photo> { $0.id == id })
        }
        descriptor.fetchLimit = 1
        let existing = try modelContext.fetch(descriptor).first
        let photo = existing ?? Photo(assetLocalIdentifier: assetLocalIdentifier, imageData: imageData, filmPresetName: filmPresetName)
        if existing == nil { photo.id = id; modelContext.insert(photo) }
        photo.timestamp = captureDate
        photo.assetLocalIdentifier = assetLocalIdentifier
        photo.imageData = imageData
        photo.filmPresetName = filmPresetName
        if let label = filmDisplayLabel { photo.filmDisplayLabel = label }
        photo.isLivePhoto = isLivePhoto
        photo.latitude = latitude
        photo.longitude = longitude
        photo.altitude = altitude
        photo.locationTimestamp = locationTimestamp
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw error }
        return photo.id
    }

    /// 批量删除。在自己的 modelContext 上跑，主 @Query 通过 SwiftData 跨 context 通知自动刷新。
    /// 用 `#Predicate` 一次 fetch 出对应 Photo 实例再 delete——避免主线程把模型对象传过来跨 actor。
    @discardableResult
    func delete(ids: [UUID], journal: CaptureJournal = .application) throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { idSet.contains($0.id) })
        let photos = try modelContext.fetch(descriptor)
        let inventory = try journal.inventory()
        let assets = Set(photos.compactMap(\.assetLocalIdentifier))
        let discarded = inventory.jobs.filter { ids.contains($0.id) || ($0.assetIdentifier.map { assets.contains($0) } ?? false) }
        let committedDirectories = Set(discarded.map { $0.id.uuidString })
        let discardedIssues = inventory.issues.filter { idSet.contains($0.captureID) && !committedDirectories.contains($0.id) }
        var marked: [UUID] = []
        var markedIssues: [CaptureRecoveryIssue] = []
        do {
            for job in discarded {
                try journal.markDiscarded(job.id)
                marked.append(job.id)
            }
            for issue in discardedIssues {
                guard issue.reason != .discardedFiles else { continue }
                try journal.markDiscarded(issue)
                markedIssues.append(issue)
            }
            for photo in photos { modelContext.delete(photo) }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            for id in marked {
                do { try journal.undoDiscard(id) }
                catch { Diagnostics.emit("capture_discard_rollback_failed", id: id.uuidString, fields: Diagnostics.errorFields(error)) }
            }
            for issue in markedIssues {
                do { try journal.undoDiscard(issue) }
                catch { Diagnostics.emit("capture_discard_rollback_failed", id: issue.id, fields: Diagnostics.errorFields(error)) }
            }
            throw error
        }
        for job in discarded { try? journal.finish(job.id) }
        for issue in discardedIssues { try? journal.discardRecoveryFiles(for: issue) }
        return idSet.union(discarded.map(\.id)).union(discardedIssues.map(\.captureID))
    }

    /// 反向同步（library → app）：把指向「系统相册里已不存在的资产」的索引行剔除。真相源在相册，
    /// 用户在系统「照片」里删掉某张后，这里据「资产是否还 fetch 得到」判定并删行（@Query 自动刷新）。
    ///
    /// 安全前提：仅在完整 .authorized 时执行——未授权时 fetch 全空会被误判成「全部删除」；
    /// .limited 下 fetch 不到 ≠ 已删除（资产可能只是被移出授权选集 / iCloud 恢复未本地化）。
    /// `existingAssetIdentifiers` 在这两种情形都返回 nil，这里直接跳过，**绝不误删**。
    /// 只处理有 assetLocalIdentifier 的行；兜底内部照片（identifier == nil）永不在此剔除。
    func pruneDeletedAssets() {
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.assetLocalIdentifier != nil })
        guard let photos = try? modelContext.fetch(descriptor), !photos.isEmpty else { return }
        let ids = photos.compactMap { $0.assetLocalIdentifier }
        guard let existing = PhotoLibrary.existingAssetIdentifiers(from: ids) else { return }

        var prunedRowIDs: [UUID] = []
        for photo in photos {
            guard let aid = photo.assetLocalIdentifier, !existing.contains(aid) else { continue }
            prunedRowIDs.append(photo.id)
            modelContext.delete(photo)
        }
        guard !prunedRowIDs.isEmpty else { return }
        try? modelContext.save()
        for id in prunedRowIDs { ImageLoader.shared.removeDiskCache(for: id) }
        Log.save.info("photos_pruned_deleted count=\(prunedRowIDs.count)")
    }

    /// 与系统相册的全量对账入口：迁移待入库的内部照片 + 剪掉已删资产的索引行 + 回填「资产在
    /// 相簿里但索引缺行」的孤儿。两个触发点（GalleryView 冷同步 / PhotoLibrarySync 实时回调）
    /// 统一走这里。migrate 在最前：同一次对账内，backfill 看到的索引已包含刚迁移的行，不会
    /// 把迁移产生的新资产误判成孤儿回填出重复行。
    private var isReconciling = false

    func reconcileWithLibrary() async {
        guard !isReconciling,
              let inventory = try? CaptureJournal.application.inventory() else { return }
        isReconciling = true
        defer { isReconciling = false }
        let pendingIDs = Set(inventory.jobs.map(\.id)).union(inventory.issues.map(\.captureID))
        await migrateInternalPhotos(excluding: pendingIDs)
        pruneDeletedAssets()
        backfillOrphanAssets(excluding: pendingIDs)
    }

    /// 内部照片迁入系统相册（架构注释承诺的 "PhotoMigrator"）：兜底暂存（拍摄时相册写入失败）
    /// 与旧版本遗留的行 assetLocalIdentifier == nil、字节在 Photo.imageData——把字节写进相册
    /// 拿回 identifier，行切到索引模式、blob 置 nil 释放 externalStorage，并清掉内部路径的磁盘
    /// 缩略图缓存（迁移后取图走 PHImageManager，旧缓存永不再被读）。
    ///
    /// 安全序：先写相册、成功才改行，逐张提交——任一时刻崩溃都不丢照片，最坏是「资产已写、
    /// 行未更新」，下次 backfill 回填 + 本行重迁出现一张重复（概率极小，可手删）。
    /// 仅在已授权时工作（绝不从后台维护路径触发权限弹窗）；单张失败（磁盘满 / iCloud 异常）
    /// 即中断，剩余的留待下次 reconcile 重试。
    private func migrateInternalPhotos(excluding pendingIDs: Set<UUID>) async {
        guard PhotoLibrary.isAuthorized else { return }
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.assetLocalIdentifier == nil })
        guard let photos = try? modelContext.fetch(descriptor), !photos.isEmpty else { return }

        var migratedIDs: [UUID] = []
        for photo in photos {
            guard !pendingIDs.contains(photo.id),
                  !FileManager.default.fileExists(atPath: CaptureJournal.application.directory(for: photo.id).path),
                  let data = photo.imageData else { continue }
            do {
                let assetID = try await PhotoLibrary.save(
                    imageData: data,
                    creationDate: photo.timestamp,
                    latitude: photo.latitude,
                    longitude: photo.longitude,
                    altitude: photo.altitude,
                    locationTimestamp: photo.locationTimestamp,
                    captureID: photo.id
                )
                photo.assetLocalIdentifier = assetID
                photo.imageData = nil
                photo.isLivePhoto = false   // 兜底只暂存了静态图，配对视频已不可得
                try modelContext.save()
                migratedIDs.append(photo.id)
            } catch {
                Log.save.error("internal_photo_migrate_failed id=\(photo.id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                break
            }
        }
        guard !migratedIDs.isEmpty else { return }
        for id in migratedIDs { ImageLoader.shared.removeDiskCache(for: id) }
        Log.save.info("internal_photos_migrated count=\(migratedIDs.count)")
    }

    // MARK: - 启动维护（孤儿文件对账）

    /// 启动时后台调一次（MainTabView.task）：清掉各类「正常路径清不到」的磁盘残留。
    /// 1. tmp 残留（拍摄中途崩溃/强杀留下的 Live Photo 临时视频、上次会话的分享导出）
    /// 2. 磁盘缩略图缓存孤儿（行已删但当时清理失败/崩溃的残留）——只删「无对应行」的文件，
    ///    现存行的缓存一律保留，绝不误删
    /// 3. CustomLUTs 目录孤儿 .cube（文件写入成功、行保存失败的残留）
    /// fetch 失败时跳过对应步骤（宁可这次不清，绝不把有效文件当孤儿删掉）。
    func performLaunchMaintenance() {
        Self.sweepTemporaryFiles()

        if let photos = try? modelContext.fetch(FetchDescriptor<Photo>()) {
            ImageLoader.shared.pruneOrphanDiskCache(keepingIDs: Set(photos.map { $0.id.uuidString }))
        }

        if let luts = try? modelContext.fetch(FetchDescriptor<CustomLUT>()) {
            let valid = Set(luts.map(\.fileName))
            let dir = CustomLUT.storageDirectory
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for file in files where !valid.contains(file) {
                    let url = dir.appendingPathComponent(file)
                    guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          modified < Date().addingTimeInterval(-86_400) else { continue }
                    try? FileManager.default.removeItem(at: url)
                    Log.save.info("orphan_lut_file_removed name=\(file, privacy: .public)")
                }
            }
        }
    }

    /// tmp 残留清扫。只挑本 app 已知前缀，仅清理超过一天的旧文件，允许其他窗口仍有拍摄任务：
    /// - livephoto_src_/livephoto_lut_：拍摄中途崩溃/强杀留下的临时视频（每个 ~2-6MB）
    /// 不动 livephoto_prewarm_*：ContentView 的启动预热可能与本清扫并发，其文件自身 defer 即删。
    nonisolated static func sweepTemporaryFiles() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        if let files = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in files {
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                guard let modified, modified < Date().addingTimeInterval(-86_400) else { continue }
                let name = url.lastPathComponent
                if name.hasPrefix("livephoto_src_") || name.hasPrefix("livephoto_lut_") {
                    try? fm.removeItem(at: url)
                    Log.save.info("stale_tmp_movie_removed name=\(name, privacy: .public)")
                }
            }
        }
        // Share exports are managed by their owner; another window may still be sharing.
    }

    /// 正向同步（library → app）：JustShoot 相簿里存在、但索引没有对应行的资产，补建索引行。
    /// 这是「资产已写入相册、PhotoSaver.save 写索引却失败」唯一的恢复路径——没有它照片会永远
    /// 存在于相册却不出现在 app 画廊。也顺带覆盖 iCloud 把另一台设备 JustShoot 相簿同步过来的
    /// 资产。胶片元数据已不可知，回填行 filmPresetName 为 nil（显示 "Default"）。
    ///
    /// 30s 宽限：拍摄管线是「先写相册、后写索引」，本方法又会被保存自身触发的相册变更回调唤起
    /// ——不留宽限会在索引写入前抢先回填出重复行。creationDate 是拍摄时刻，30s 远大于整条
    /// 后处理管线的最坏耗时。
    private func backfillOrphanAssets(excluding pendingIDs: Set<UUID>) {
        guard let inventory = try? CaptureJournal.application.inventory() else { return }
        let protectedIDs = pendingIDs.union(inventory.jobs.map(\.id)).union(inventory.issues.map(\.captureID))
        guard let albumAssets = PhotoLibrary.albumAssetInfo(), !albumAssets.isEmpty else { return }
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.assetLocalIdentifier != nil })
        guard let photos = try? modelContext.fetch(descriptor) else { return }
        let indexed = Set(photos.compactMap(\.assetLocalIdentifier))
        let cutoff = Date().addingTimeInterval(-30)

        var added = 0
        for asset in albumAssets {
            if let captureID = asset.captureID, protectedIDs.contains(captureID) { continue }
            guard !indexed.contains(asset.id) else { continue }
            if let created = asset.creationDate, created > cutoff { continue }   // 在途拍摄宽限
            let photo = Photo(assetLocalIdentifier: asset.id, imageData: nil)
            if let created = asset.creationDate { photo.timestamp = created }
            photo.isLivePhoto = asset.isLivePhoto
            modelContext.insert(photo)
            added += 1
        }
        guard added > 0 else { return }
        try? modelContext.save()
        Log.save.info("photos_backfilled_orphans count=\(added)")
    }
}
