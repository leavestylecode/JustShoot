import Foundation
import SwiftData
import ImageIO

// MARK: - 照片输出画质（用户可配置，存 @AppStorage("photoOutputQuality")）
//
// LUT 渲染（heif10Representation）+ metadata 注入（AddImageFromSource 重编码）两步都用这个
// compressionQuality。HEVC 的 质量→体积 高度非线性：q1.0 近无损但 12MP 就 8–10MB，从 1.0 往下
// 掉得极快。默认 .standard(0.8) 对齐 iPhone 原相机出片体积（约 2–3MB）与观感；想要近无损用
// .maximum，想省空间用 .compact。sizeHint 的 MB 区间是 12MP HEIC/HEVC 的经验值（实测可微调）。
enum PhotoQuality: String, CaseIterable, Identifiable, Sendable {
    case maximum
    case high
    case standard
    case compact

    var id: String { rawValue }

    /// kCGImageDestinationLossyCompressionQuality 值（0...1）。
    var compressionQuality: CGFloat {
        switch self {
        case .maximum:  return 1.0
        case .high:     return 0.9
        case .standard: return 0.8
        case .compact:  return 0.6
        }
    }

    /// 默认档：对齐 iPhone 原相机。
    static let `default`: PhotoQuality = .standard

    /// 大致文件体积（12MP HEIC 经验值）。纯数字 + "MB" 跨语言通用，无需本地化——设置页每行右侧
    /// 直接显示它，作为档位之间最直观的区分。
    var approximateSize: String {
        switch self {
        case .maximum:  return "8–10 MB"
        case .high:     return "4–5 MB"
        case .standard: return "2–3 MB"
        case .compact:  return "1–1.5 MB"
        }
    }

    /// 档位本地化名（设置页行标题 + VoiceOver）。仅 4 个最短词，翻译负担极小。
    var displayName: String {
        switch self {
        case .maximum:  return String(localized: "Maximum")
        case .high:     return String(localized: "High")
        case .standard: return String(localized: "Standard")
        case .compact:  return String(localized: "Space Saving")
        }
    }
}

// MARK: - EXIF 解析结果（一次解析，多处使用）
struct ParsedExifInfo: Sendable {
    let iso: String
    let shutterSpeed: String
    let aperture: String
    let focalLength: String
    let exposureMode: String
    let flashMode: String
    let gpsInfo: (latitude: String, longitude: String, altitude: String)?
    let deviceInfo: (make: String, model: String, software: String)?
    let lensInfo: String
    /// 像素尺寸——与其它 EXIF 字段同一次解析得到，省掉信息面板里另开一个 CGImageSource 读 blob。
    let pixelWidth: Int?
    let pixelHeight: Int?

    private static var unknownString: String { String(localized: "Unknown") }
    private static var unknownLensString: String { String(localized: "Unknown lens") }
    private static var builtInLensString: String { String(localized: "Built-in lens") }
    private static var flashOnString: String { String(localized: "Flash on") }
    private static var flashOffString: String { String(localized: "Flash off") }
    private static var autoExposureString: String { String(localized: "Auto exposure") }
    private static var manualExposureString: String { String(localized: "Manual exposure") }
    private static var autoBracketExposureString: String { String(localized: "Auto bracket exposure") }

    static var empty: ParsedExifInfo {
        ParsedExifInfo(
            iso: unknownString, shutterSpeed: unknownString, aperture: unknownString,
            focalLength: unknownString, exposureMode: unknownString, flashMode: unknownString,
            gpsInfo: nil, deviceInfo: nil, lensInfo: unknownLensString,
            pixelWidth: nil, pixelHeight: nil
        )
    }

    /// 从 imageData 一次性解析所有 EXIF 字段
    static func parse(from imageData: Data) -> ParsedExifInfo {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return .empty
        }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiffDict = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let gpsDict = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]

        // ISO
        let iso: String = {
            guard let exif,
                  let isoValues = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
                  let first = isoValues.first else { return unknownString }
            return "ISO \(first)"
        }()

        // Shutter Speed
        let shutterSpeed: String = {
            guard let exif,
                  let exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double,
                  exposureTime > 0 else { return unknownString }
            if exposureTime >= 1 {
                return String(format: "%.1fs", exposureTime)
            } else {
                // 照片可能被第三方 app 编辑过，EXIF 不可信：病态极小曝光值会让 Int(Double)
                // 越界 trap（运行时崩溃，不是 clamp）。越界时按未知处理。
                let denom = 1 / exposureTime
                guard denom.isFinite, denom < Double(Int.max) else { return unknownString }
                return "1/\(Int(denom))s"
            }
        }()

        // Aperture
        let aperture: String = {
            guard let exif,
                  let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double else { return unknownString }
            return String(format: "f/%.1f", fNumber)
        }()

        // Focal Length
        let focalLength: String = {
            guard let exif else { return unknownString }
            if let fl35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int {
                return "\(fl35)mm"
            }
            if let fl = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                return String(format: "%.0fmm", fl)
            }
            return unknownString
        }()

        // Exposure Mode
        let exposureMode: String = {
            guard let exif,
                  let mode = exif[kCGImagePropertyExifExposureMode as String] as? Int else { return unknownString }
            switch mode {
            case 0: return autoExposureString
            case 1: return manualExposureString
            case 2: return autoBracketExposureString
            default: return unknownString
            }
        }()

        // Flash
        let flashMode: String = {
            guard let exif,
                  let flash = exif[kCGImagePropertyExifFlash as String] as? Int else { return unknownString }
            return (flash & 0x01 != 0) ? flashOnString : flashOffString
        }()

        // GPS
        let gpsInfo: (latitude: String, longitude: String, altitude: String)? = {
            guard let gpsDict,
                  let lat = gpsDict[kCGImagePropertyGPSLatitude as String] as? Double,
                  let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef as String] as? String,
                  let lon = gpsDict[kCGImagePropertyGPSLongitude as String] as? Double,
                  let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef as String] as? String else { return nil }
            let altitude = gpsDict[kCGImagePropertyGPSAltitude as String] as? Double ?? 0
            return (
                latitude: String(format: "%.6f°%@", lat, latRef),
                longitude: String(format: "%.6f°%@", lon, lonRef),
                altitude: String(format: "%.1fm", altitude)
            )
        }()

        // Device
        let deviceInfo: (make: String, model: String, software: String)? = {
            let make = tiffDict?[kCGImagePropertyTIFFMake as String] as? String ?? unknownString
            let model = tiffDict?[kCGImagePropertyTIFFModel as String] as? String ?? unknownString
            let software = tiffDict?[kCGImagePropertyTIFFSoftware as String] as? String ?? unknownString
            return (make: make, model: model, software: software)
        }()

        // Lens
        let lensInfo: String = {
            if let lensModel = exif?["LensModel"] as? String { return lensModel }
            if let lensMake = exif?["LensMake"] as? String { return lensMake }
            if let make = tiffDict?[kCGImagePropertyTIFFMake as String] as? String,
               let model = tiffDict?[kCGImagePropertyTIFFModel as String] as? String {
                return String(format: String(localized: "%1$@ %2$@ built-in lens"), make, model)
            }
            return builtInLensString
        }()

        // 像素尺寸直接从已读到的 properties 取——不必再开一个 CGImageSource。
        let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Int
        let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Int

        return ParsedExifInfo(
            iso: iso, shutterSpeed: shutterSpeed, aperture: aperture,
            focalLength: focalLength, exposureMode: exposureMode, flashMode: flashMode,
            gpsInfo: gpsInfo, deviceInfo: deviceInfo, lensInfo: lensInfo,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight
        )
    }
}

// MARK: - Photo 模型
@Model
final class Photo: Identifiable {
    var id: UUID
    var timestamp: Date
    /// 系统相册 PHAsset 的本地标识符——**真相源**。迁移完成后所有照片都有值；仅在「拍摄时相册
    /// 写入失败、字节兜底暂存待迁移」或「旧版本遗留尚未迁移」时为 nil。
    var assetLocalIdentifier: String?
    /// 遗留 / 兜底内部字节：新架构默认 nil（真相源在系统相册）。仅当相册写入失败兜底暂存、或旧
    /// 版本数据尚未迁移时有值；迁入相册后置 nil 以释放 externalStorage。
    @Attribute(.externalStorage) var imageData: Data?
    var filmPresetName: String?
    var filmDisplayLabel: String?
    /// 是否为 Live Photo（拍摄时套了 LUT 的静态图 + 配对视频）。拍摄写入，画廊角标 / 详情页是否启用
    /// PHLivePhotoView 播放都读它——避免每个 cell 异步查 PHAsset.mediaSubtypes。旧照片默认 false。
    var isLivePhoto: Bool = false
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var locationTimestamp: Date?

    /// EXIF 解析缓存（Transient：不持久化，按需解析一次）
    @Transient private var _parsedExif: ParsedExifInfo?

    init(assetLocalIdentifier: String?, imageData: Data?, filmPresetName: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.assetLocalIdentifier = assetLocalIdentifier
        self.imageData = imageData
        self.filmPresetName = filmPresetName
    }

    /// 一次性解析并缓存所有 EXIF 信息。仅对遗留内部字节有效；资产照片的 EXIF 由
    /// `PhotoImage.exifData` 异步从相册取数据后解析（见 PhotoInfoPanel）。
    var parsedExif: ParsedExifInfo {
        if let cached = _parsedExif { return cached }
        guard let data = imageData else { return .empty }
        let info = ParsedExifInfo.parse(from: data)
        _parsedExif = info
        return info
    }

    // MARK: - 便捷属性（全部从缓存读取，不再重复解析）
    var iso: String { parsedExif.iso }
    var shutterSpeed: String { parsedExif.shutterSpeed }
    var aperture: String { parsedExif.aperture }
    var focalLength: String { parsedExif.focalLength }
    var exposureMode: String { parsedExif.exposureMode }
    var flashMode: String { parsedExif.flashMode }
    var gpsInfo: (latitude: String, longitude: String, altitude: String)? { parsedExif.gpsInfo }
    var deviceInfo: (make: String, model: String, software: String)? { parsedExif.deviceInfo }
    var lensInfo: String { parsedExif.lensInfo }
}

// Lets the `KeyPath<Photo, String?>` captured by the `#Predicate` macro
// expansion satisfy Swift 6 strict-concurrency's Sendable requirement on
// captures. The standard library does not declare `AnyKeyPath: Sendable`,
// but property KeyPaths are immutable values. The conformance here covers
// every KeyPath subclass (KeyPath / WritableKeyPath / ReferenceWritableKeyPath
// all inherit from AnyKeyPath).
extension AnyKeyPath: @retroactive @unchecked Sendable {}

// MARK: - Film presets
enum FilmPreset: String, CaseIterable, Identifiable, Sendable {
    case fujiC200
    case fujiPro400H
    case fujiProvia100F
    case kodakPortra400
    case kodakVision5219 // 500T
    case kodakVision5203 // 50D
    case kodak5207       // 250D
    case harmanPhoenix200

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fujiC200: return "Fuji C200"
        case .fujiPro400H: return "Fuji Pro 400H"
        case .fujiProvia100F: return "Fuji Provia 100F"
        case .kodakPortra400: return "Kodak Portra 400"
        case .kodakVision5219: return "Kodak Vision3 500T (5219)"
        case .kodakVision5203: return "Kodak Vision3 50D (5203)"
        case .kodak5207: return "Kodak 250D (5207)"
        case .harmanPhoenix200: return "Harman Phoenix 200"
        }
    }

    var iso: Float {
        switch self {
        case .fujiC200: return 200
        case .fujiPro400H: return 400
        case .fujiProvia100F: return 100
        case .kodakPortra400: return 400
        case .kodakVision5219: return 500
        case .kodakVision5203: return 50
        case .kodak5207: return 250
        case .harmanPhoenix200: return 200
        }
    }

    var lutResourceName: String {
        switch self {
        case .fujiC200: return "FujiC200"
        case .fujiPro400H: return "FujiPro400H"
        case .fujiProvia100F: return "FujiProvia100F"
        case .kodakPortra400: return "KodakPortra400"
        case .kodakVision5219: return "KodakVision5219"
        case .kodakVision5203: return "KodakVision5203"
        case .kodak5207: return "Kodak5207"
        case .harmanPhoenix200: return "HarmanPhoenix200"
        }
    }

    /// Filename of the bundled film-card image used as this preset's cover.
    /// Hand-picked from `Resources/cards/*.heic` to match each LUT's stock —
    /// 5203 falls back to CineStill 50D since the catalog has no Kodak-branded
    /// Vision3 50D card.
    var libraryCardImage: String {
        switch self {
        case .fujiC200:         return "00202_000.heic"
        case .fujiPro400H:      return "00022_000.heic"
        case .fujiProvia100F:   return "00055_000.heic"
        case .kodakPortra400:   return "00200_000.heic"
        case .kodakVision5219:  return "00185_000.heic"
        case .kodakVision5203:  return "00254_000.heic"
        case .kodak5207:        return "00001_000.heic"
        case .harmanPhoenix200: return "00004_000.heic"
        }
    }
}

extension Photo {
    var filmPreset: FilmPreset? {
        guard let name = filmPresetName else { return nil }
        return FilmPreset(rawValue: name)
    }

    var filmDisplayName: String {
        filmPreset?.displayName ?? filmDisplayLabel ?? String(localized: "Default")
    }
}

// MARK: - 后台保存 actor
//
// 把 Photo 插入 + context.save() 从主线程移走。connect 到同一个 ModelContainer 后，
// SwiftData 会把 actor 内的写入广播到主 context 的 @Query —— gallery / 计数 UI 自动刷新。
//
// 为什么不直接在 Task.detached 里 `container.mainContext`：mainContext 必须在 MainActor
// 访问，会重新阻塞主线程；@ModelActor 自动给 actor 一个**自己的** modelContext，跟主 context
// 完全隔离，save 全程在后台 actor 上跑。
@ModelActor
actor PhotoSaver {
    /// 返回新 photo 的 id；失败抛错由 caller 报给 UI。
    func save(
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
        let photo = Photo(assetLocalIdentifier: assetLocalIdentifier, imageData: imageData, filmPresetName: filmPresetName)
        if let label = filmDisplayLabel { photo.filmDisplayLabel = label }
        photo.isLivePhoto = isLivePhoto
        photo.latitude = latitude
        photo.longitude = longitude
        photo.altitude = altitude
        photo.locationTimestamp = locationTimestamp
        modelContext.insert(photo)
        try modelContext.save()
        return photo.id
    }

    /// 批量删除。在自己的 modelContext 上跑，主 @Query 通过 SwiftData 跨 context 通知自动刷新。
    /// 用 `#Predicate` 一次 fetch 出对应 Photo 实例再 delete——避免主线程把模型对象传过来跨 actor。
    func delete(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { idSet.contains($0.id) })
        let photos = try modelContext.fetch(descriptor)
        for photo in photos { modelContext.delete(photo) }
        try modelContext.save()
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
    func reconcileWithLibrary() async {
        await migrateInternalPhotos()
        pruneDeletedAssets()
        backfillOrphanAssets()
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
    func migrateInternalPhotos() async {
        guard PhotoLibrary.isAuthorized else { return }
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.assetLocalIdentifier == nil })
        guard let photos = try? modelContext.fetch(descriptor), !photos.isEmpty else { return }

        var migratedIDs: [UUID] = []
        for photo in photos {
            guard let data = photo.imageData else { continue }
            do {
                let assetID = try await PhotoLibrary.save(
                    imageData: data,
                    creationDate: photo.timestamp,
                    latitude: photo.latitude,
                    longitude: photo.longitude,
                    altitude: photo.altitude,
                    locationTimestamp: photo.locationTimestamp
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
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
                    Log.save.info("orphan_lut_file_removed name=\(file, privacy: .public)")
                }
            }
        }
    }

    /// tmp 残留清扫。只挑本 app 已知前缀，且在启动早期调用（无在途拍摄/分享，列目录无竞争）：
    /// - livephoto_src_/livephoto_lut_：拍摄中途崩溃/强杀留下的临时视频（每个 ~2-6MB）
    /// - Share/：上次会话导出的分享 JPEG（正常路径要等到下一次分享前才清）
    /// 不动 livephoto_prewarm_*：ContentView 的启动预热可能与本清扫并发，其文件自身 defer 即删。
    nonisolated static func sweepTemporaryFiles() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        if let files = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for url in files {
                let name = url.lastPathComponent
                if name.hasPrefix("livephoto_src_") || name.hasPrefix("livephoto_lut_") {
                    try? fm.removeItem(at: url)
                    Log.save.info("stale_tmp_movie_removed name=\(name, privacy: .public)")
                }
            }
        }
        try? fm.removeItem(at: tmp.appendingPathComponent("Share", isDirectory: true))
    }

    /// 正向同步（library → app）：JustShoot 相簿里存在、但索引没有对应行的资产，补建索引行。
    /// 这是「资产已写入相册、PhotoSaver.save 写索引却失败」唯一的恢复路径——没有它照片会永远
    /// 存在于相册却不出现在 app 画廊。也顺带覆盖 iCloud 把另一台设备 JustShoot 相簿同步过来的
    /// 资产。胶片元数据已不可知，回填行 filmPresetName 为 nil（显示 "Default"）。
    ///
    /// 30s 宽限：拍摄管线是「先写相册、后写索引」，本方法又会被保存自身触发的相册变更回调唤起
    /// ——不留宽限会在索引写入前抢先回填出重复行。creationDate 是拍摄时刻，30s 远大于整条
    /// 后处理管线的最坏耗时。
    private func backfillOrphanAssets() {
        guard let albumAssets = PhotoLibrary.albumAssetInfo(), !albumAssets.isEmpty else { return }
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { $0.assetLocalIdentifier != nil })
        guard let photos = try? modelContext.fetch(descriptor) else { return }
        let indexed = Set(photos.compactMap(\.assetLocalIdentifier))
        let cutoff = Date().addingTimeInterval(-30)

        var added = 0
        for asset in albumAssets {
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

// MARK: - 自定义 LUT 模型
@Model
final class CustomLUT: Identifiable {
    var id: UUID
    var displayName: String
    var fileName: String
    var iso: Float
    var dimension: Int
    var createdAt: Date

    init(displayName: String, fileName: String, iso: Float, dimension: Int) {
        self.id = UUID()
        self.displayName = displayName
        self.fileName = fileName
        self.iso = iso
        self.dimension = dimension
        self.createdAt = Date()
    }

    static var storageDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("CustomLUTs", isDirectory: true)
    }

    var fileURL: URL {
        Self.storageDirectory.appendingPathComponent(fileName)
    }
}

// MARK: - 统一 LUT 来源
enum FilmSource: Hashable, Identifiable {
    case preset(FilmPreset)
    case custom(id: UUID, displayName: String, iso: Float, fileName: String)

    var id: String {
        switch self {
        case .preset(let p): return p.rawValue
        case .custom(let id, _, _, _): return id.uuidString
        }
    }

    var displayName: String {
        switch self {
        case .preset(let p): return p.displayName
        case .custom(_, let name, _, _): return name
        }
    }

    var iso: Float {
        switch self {
        case .preset(let p): return p.iso
        case .custom(_, _, let iso, _): return iso
        }
    }

    /// Photo.filmPresetName 存储值（用于查询过滤）
    var photoFilterName: String {
        switch self {
        case .preset(let p): return p.rawValue
        case .custom(let id, _, _, _): return "custom:\(id.uuidString)"
        }
    }

    /// FilmProcessor 缓存键
    var lutCacheKey: String {
        switch self {
        case .preset(let p): return p.lutResourceName
        case .custom(let id, _, _, _): return "custom_\(id.uuidString)"
        }
    }

    static func from(_ customLUT: CustomLUT) -> FilmSource {
        .custom(id: customLUT.id, displayName: customLUT.displayName,
                iso: customLUT.iso, fileName: customLUT.fileName)
    }
}
