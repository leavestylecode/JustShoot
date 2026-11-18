import Foundation
import SwiftData

/// Reconciles the Photos source of truth with the lightweight local index.
@ModelActor
actor PhotoLibraryReconciler {
    nonisolated static func background(container: ModelContainer) async -> Self {
        await Task.detached(priority: .utility) { Self(modelContainer: container) }.value
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

    /// 补录新旧相簿中缺少索引的资产，包括由 iCloud 从其他设备同步的照片。
    /// 胶片元数据已不可知，回填行 filmPresetName 为 nil（显示 "Default"）。
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
