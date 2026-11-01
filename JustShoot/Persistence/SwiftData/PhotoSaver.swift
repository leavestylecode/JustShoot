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
}
