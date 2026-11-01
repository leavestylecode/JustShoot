import Foundation
import SwiftData

/// Best-effort launch cleanup is separate from accepted capture/index transactions.
@ModelActor
actor LibraryMaintenance {
    nonisolated static func background(container: ModelContainer) async -> Self {
        await Task.detached(priority: .utility) { Self(modelContainer: container) }.value
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
            let dir = CustomLUTFiles.directory
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
    /// 不动 livephoto_prewarm_*：FilmHomeView 的启动预热可能与本清扫并发，其文件自身 defer 即删。
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

}
