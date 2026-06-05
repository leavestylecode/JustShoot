import Foundation
import SwiftData
import ImageIO

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
                return "1/\(Int(1 / exposureTime))s"
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
        latitude: Double?,
        longitude: Double?,
        altitude: Double?,
        locationTimestamp: Date?
    ) throws -> UUID {
        let photo = Photo(assetLocalIdentifier: assetLocalIdentifier, imageData: imageData, filmPresetName: filmPresetName)
        if let label = filmDisplayLabel { photo.filmDisplayLabel = label }
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
    /// 安全前提：仅在已授权时执行——未授权时 fetch 会全空，会被误判成「全部删除」。
    /// `existingAssetIdentifiers` 在未授权时返回 nil，这里直接跳过，**绝不误删**。
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
