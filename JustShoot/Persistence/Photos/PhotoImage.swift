import UIKit
import SwiftData

/// Immutable lookup key for gallery work that may outlive a local-to-Photos migration.
struct PhotoFileReference: Equatable, Sendable {
    let photoID: UUID
    let assetID: String?

    @MainActor
    init(_ photo: Photo) {
        photoID = photo.id
        assetID = photo.assetLocalIdentifier
    }

    func filename(localExtension: String? = nil, journal: CaptureJournal? = nil) -> String? {
        if let assetID { return PhotoLibrary.stillFilename(id: assetID) }
        let journal = journal ?? .application
        let number: Int?
        do { number = try journal.job(for: photoID).recipe.fileNumber }
        catch CocoaError.fileReadNoSuchFile {
            // A legacy internal photo has no journal. Migration uses its UUID-based name.
            guard !FileManager.default.fileExists(atPath: journal.directory(for: photoID).path) else { return nil }
            number = nil
        } catch { return nil }
        guard let stem = CaptureFilename.stem(id: photoID, number: number) else { return nil }
        return localExtension.map { stem + "." + CaptureFilename.normalizedExtension($0) } ?? stem
    }
}

// MARK: - 统一取图门面
//
// 调用点（grid cell / detail pager / scrubber / info 面板）只跟它打交道：有 assetLocalIdentifier
// 走系统相册，否则回退到遗留内部 blob（ImageLoader）。读取 Photo 属性发生在 @MainActor，提取后
// 才进入 PhotoKit 异步路径。
enum PhotoImage {
    @MainActor
    private static func isAvailable(_ photo: Photo, in context: ModelContext?) -> Bool {
        guard !Task.isCancelled, !photo.isDeleted else { return false }
        // A saved deletion can detach the model before this request starts. Only
        // a model that has never been associated with a store can load without a context.
        guard let context else { return photo.persistentModelID.storeIdentifier == nil }
        // iOS 17 does not reliably set isDeleted until a pending deletion is saved.
        return photo.modelContext != nil && !context.deletedModelsArray.contains { $0 === photo }
    }

    @MainActor
    static func thumbnail(for photo: Photo, maxPixel: Int, trace: DiagnosticTrace? = nil,
                          loader: ImageLoader = .shared) async -> UIImage? {
        let context = photo.modelContext
        guard isAvailable(photo, in: context) else { return nil }
        if let aid = photo.assetLocalIdentifier {
            let image = await AssetImageLoader.shared.thumbnail(id: aid, maxPixel: maxPixel, trace: trace)
            return isAvailable(photo, in: context) ? image : nil
        }
        let id = photo.id
        if let cached = loader.cachedThumbnail(for: id, maxPixel: maxPixel) { return cached }
        let disk = await loader.cachedOrDiskThumbnail(photoId: id, maxPixel: maxPixel)
        guard isAvailable(photo, in: context) else { return nil }
        // Migration may have completed while the disk request was suspended.
        if let aid = photo.assetLocalIdentifier {
            let image = await AssetImageLoader.shared.thumbnail(id: aid, maxPixel: maxPixel, trace: trace)
            return isAvailable(photo, in: context) ? image : nil
        }
        if let disk { return disk }
        if let data = photo.imageData {
            let image = await loader.loadThumbnail(imageData: data, photoId: id, maxPixel: maxPixel)
            return isAvailable(photo, in: context) ? image : nil
        }
        return nil
    }

    @MainActor
    static func preview(for photo: Photo, maxPixel: Int, trace: DiagnosticTrace? = nil,
                        loader: ImageLoader = .shared) async -> UIImage? {
        let context = photo.modelContext
        guard isAvailable(photo, in: context) else { return nil }
        if let aid = photo.assetLocalIdentifier {
            let image = await AssetImageLoader.shared.preview(id: aid, maxPixel: maxPixel, trace: trace)
            return isAvailable(photo, in: context) ? image : nil
        }
        let id = photo.id
        if let cached = loader.cachedPreview(for: id, maxPixel: maxPixel) { return cached }
        let disk = await loader.cachedOrDiskPreview(photoId: id, maxPixel: maxPixel)
        guard isAvailable(photo, in: context) else { return nil }
        if let aid = photo.assetLocalIdentifier {
            let image = await AssetImageLoader.shared.preview(id: aid, maxPixel: maxPixel, trace: trace)
            return isAvailable(photo, in: context) ? image : nil
        }
        if let disk { return disk }
        if let data = photo.imageData {
            let image = await loader.loadPreview(imageData: data, photoId: id, maxPixel: maxPixel)
            return isAvailable(photo, in: context) ? image : nil
        }
        return nil
    }

    @MainActor
    static func exifData(for photo: Photo) async -> Data? {
        let context = photo.modelContext
        guard isAvailable(photo, in: context) else { return nil }
        let trace = DiagnosticTrace(id: photo.id.uuidString)
        if let aid = photo.assetLocalIdentifier {
            let data = await AssetImageLoader.shared.imageData(id: aid, trace: trace)
            return isAvailable(photo, in: context) ? data : nil
        }
        return photo.imageData
    }
}
