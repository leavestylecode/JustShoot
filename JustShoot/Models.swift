import Foundation
import SwiftData
import UIKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import Metal
import os

// MARK: - 统一日志系统
//
// 用法：
//   Log.capture.info("shutter_tap preset=\(name)")
//   let t = Log.perf("lut_apply", logger: Log.lut); ...; t.end("size=\(bytes)")
//
// 过滤（Xcode Console / Terminal）:
//   log stream --predicate 'subsystem == "com.leavestylecode.JustShoot"'
//   log stream --predicate 'subsystem == "com.leavestylecode.JustShoot" && category == "camera.capture"'
//
// 事件命名约定：snake_case，参数用 key=value，时间单位 ms。
enum Log {
    static let subsystem = "com.leavestylecode.JustShoot"

    static let session     = Logger(subsystem: subsystem, category: "camera.session")
    static let capture     = Logger(subsystem: subsystem, category: "camera.capture")
    static let orientation = Logger(subsystem: subsystem, category: "camera.orient")
    static let gps         = Logger(subsystem: subsystem, category: "camera.gps")
    static let lut         = Logger(subsystem: subsystem, category: "photo.lut")
    static let save        = Logger(subsystem: subsystem, category: "photo.save")
    static let gallery     = Logger(subsystem: subsystem, category: "gallery")
    static let ui          = Logger(subsystem: subsystem, category: "ui")

    /// 测量代码段耗时
    struct PerfTimer {
        let label: String
        let logger: Logger
        let start: CFAbsoluteTime

        func end(_ extra: String = "") {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let suffix = extra.isEmpty ? "" : " \(extra)"
            logger.info("⏱ \(label) took=\(String(format: "%.1f", ms))ms\(suffix)")
        }
    }

    static func perf(_ label: String, logger: Logger) -> PerfTimer {
        PerfTimer(label: label, logger: logger, start: CFAbsoluteTimeGetCurrent())
    }

    /// 当前高精度时间（秒），用于跨回调的时差测量
    static func now() -> CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    static func ms(since t0: CFAbsoluteTime) -> String {
        String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
    }
}

// MARK: - EXIF 解析结果（一次解析，多处使用）
struct ParsedExifInfo {
    let iso: String
    let shutterSpeed: String
    let aperture: String
    let focalLength: String
    let exposureMode: String
    let flashMode: String
    let gpsInfo: (latitude: String, longitude: String, altitude: String)?
    let deviceInfo: (make: String, model: String, software: String)?
    let lensInfo: String

    static let empty = ParsedExifInfo(
        iso: "未知", shutterSpeed: "未知", aperture: "未知",
        focalLength: "未知", exposureMode: "未知", flashMode: "未知",
        gpsInfo: nil, deviceInfo: nil, lensInfo: "未知镜头"
    )

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
                  let first = isoValues.first else { return "未知" }
            return "ISO \(first)"
        }()

        // Shutter Speed
        let shutterSpeed: String = {
            guard let exif,
                  let exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double else { return "未知" }
            if exposureTime >= 1 {
                return String(format: "%.1fs", exposureTime)
            } else {
                return "1/\(Int(1 / exposureTime))s"
            }
        }()

        // Aperture
        let aperture: String = {
            guard let exif,
                  let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double else { return "未知" }
            return String(format: "f/%.1f", fNumber)
        }()

        // Focal Length
        let focalLength: String = {
            guard let exif else { return "未知" }
            if let fl35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int {
                return "\(fl35)mm"
            }
            if let fl = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                return String(format: "%.0fmm", fl)
            }
            return "未知"
        }()

        // Exposure Mode
        let exposureMode: String = {
            guard let exif,
                  let mode = exif[kCGImagePropertyExifExposureMode as String] as? Int else { return "未知" }
            switch mode {
            case 0: return "自动曝光"
            case 1: return "手动曝光"
            case 2: return "自动包围曝光"
            default: return "未知"
            }
        }()

        // Flash
        let flashMode: String = {
            guard let exif,
                  let flash = exif[kCGImagePropertyExifFlash as String] as? Int else { return "未知" }
            return (flash & 0x01 != 0) ? "闪光灯开启" : "闪光灯关闭"
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
            let make = tiffDict?[kCGImagePropertyTIFFMake as String] as? String ?? "未知"
            let model = tiffDict?[kCGImagePropertyTIFFModel as String] as? String ?? "未知"
            let software = tiffDict?[kCGImagePropertyTIFFSoftware as String] as? String ?? "未知"
            return (make: make, model: model, software: software)
        }()

        // Lens
        let lensInfo: String = {
            if let lensModel = exif?["LensModel"] as? String { return lensModel }
            if let lensMake = exif?["LensMake"] as? String { return lensMake }
            if let make = tiffDict?[kCGImagePropertyTIFFMake as String] as? String,
               let model = tiffDict?[kCGImagePropertyTIFFModel as String] as? String {
                return "\(make) \(model) 内置镜头"
            }
            return "内置镜头"
        }()

        return ParsedExifInfo(
            iso: iso, shutterSpeed: shutterSpeed, aperture: aperture,
            focalLength: focalLength, exposureMode: exposureMode, flashMode: flashMode,
            gpsInfo: gpsInfo, deviceInfo: deviceInfo, lensInfo: lensInfo
        )
    }
}

@Model
final class Photo: Identifiable {
    var id: UUID
    var timestamp: Date
    @Attribute(.externalStorage) var imageData: Data
    var filmPresetName: String?
    var filmDisplayLabel: String?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var locationTimestamp: Date?

    /// EXIF 解析缓存（Transient：不持久化，按需解析一次）
    @Transient private var _parsedExif: ParsedExifInfo?

    init(imageData: Data, filmPresetName: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.imageData = imageData
        self.filmPresetName = filmPresetName
    }

    /// 一次性解析并缓存所有 EXIF 信息
    var parsedExif: ParsedExifInfo {
        if let cached = _parsedExif { return cached }
        let info = ParsedExifInfo.parse(from: imageData)
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

// 让 `#Predicate` 宏展开里的 `\Photo.filmPresetName`（`KeyPath<Photo, String?>`）
// 满足 Swift 6 完全并发对捕获 Sendable 的要求。Swift 标准库没有声明
// `AnyKeyPath: Sendable`，但属性 KeyPath 本身是不可变值；此处放宽到所有 KeyPath
// 子类（KeyPath/WritableKeyPath/ReferenceWritableKeyPath 都继承自 AnyKeyPath）。
extension AnyKeyPath: @retroactive @unchecked Sendable {}

// MARK: - 胶片预设与处理
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
}

extension Photo {
    var filmPreset: FilmPreset? {
        guard let name = filmPresetName else { return nil }
        return FilmPreset(rawValue: name)
    }

    var filmDisplayName: String {
        filmPreset?.displayName ?? filmDisplayLabel ?? "默认"
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

struct CubeLUT: Sendable {
    let data: Data
    let dimension: Int
}

// MARK: - 胶片处理器（线程安全）
final class FilmProcessor: Sendable {
    static let shared = FilmProcessor()

    private let ciContext: CIContext
    private let srgbColorSpace: CGColorSpace
    /// 保护 lutCache 的锁
    private let lock = OSAllocatedUnfairLock<LUTState>(initialState: LUTState())

    /// 锁内保护的可变状态（仅缓存 LUT 数据，不缓存 CIFilter）
    private struct LUTState {
        var lutCache: [String: CubeLUT] = [:]
    }

    private init() {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.srgbColorSpace = colorSpace
        // 显式使用 Metal 设备，确保 LUT 处理走 GPU 加速路径
        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: mtlDevice, options: [
                CIContextOption.workingColorSpace: colorSpace,
                CIContextOption.outputColorSpace: colorSpace
            ])
        } else {
            self.ciContext = CIContext(options: [
                CIContextOption.useSoftwareRenderer: false,
                CIContextOption.workingColorSpace: colorSpace,
                CIContextOption.outputColorSpace: colorSpace
            ])
        }
    }

    /// 从 .cube 文件文本解析 LUT 数据（纯函数，无锁无 I/O）
    static func parseCubeFile(_ text: String) throws -> CubeLUT {
        var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        lines.removeAll { $0.hasPrefix("#") || $0.isEmpty }

        var size = 0
        var values: [Float] = []

        for line in lines {
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                if let last = line.split(separator: " ").last, let dim = Int(last) {
                    size = dim
                }
            } else {
                let comps = line.split(separator: " ").compactMap { Float($0) }
                if comps.count == 3 {
                    values.append(contentsOf: comps)
                }
            }
        }

        guard size > 0, values.count == size * size * size * 3 else {
            throw NSError(domain: "FilmProcessor", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "LUT 解析失败或尺寸不匹配"])
        }

        var rgba: [Float] = []
        rgba.reserveCapacity(size * size * size * 4)
        for i in stride(from: 0, to: values.count, by: 3) {
            rgba.append(values[i + 0])
            rgba.append(values[i + 1])
            rgba.append(values[i + 2])
            rgba.append(1.0)
        }

        let data: Data = rgba.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        return CubeLUT(data: data, dimension: size)
    }

    /// 健壮读取 .cube 文本：部分 LUT 文件的 TITLE 含非 UTF-8 字节（如中文 GBK/Shift-JIS），
    /// 强制 UTF-8 会抛错。这里按常见编码回退，最后兜底丢弃非法字节。
    static func readCubeText(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .isoLatin1, .windowsCP1252, .macOSRoman] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        // 兜底：按 ASCII 读取，忽略非法字节（cube 文件的数据部分必然是 ASCII 数字）
        return String(decoding: data, as: UTF8.self)
    }

    func loadCubeLUT(resourceName: String) throws -> CubeLUT {
        // 快速路径：缓存命中
        if let cached = lock.withLock({ $0.lutCache[resourceName] }) {
            Log.lut.debug("lut_cache_hit name=\(resourceName, privacy: .public) dim=\(cached.dimension)")
            return cached
        }

        // 慢路径：解析 LUT 文件（锁外执行，避免长时间持锁）
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "cube") else {
            Log.lut.error("lut_resource_missing name=\(resourceName, privacy: .public)")
            throw NSError(domain: "FilmProcessor", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 LUT 资源: \(resourceName).cube"])
        }

        let timer = Log.perf("lut_load", logger: Log.lut)
        do {
            let text = try Self.readCubeText(from: url)
            let cube = try Self.parseCubeFile(text)
            lock.withLock { $0.lutCache[resourceName] = cube }
            timer.end("name=\(resourceName) dim=\(cube.dimension)")
            return cube
        } catch {
            Log.lut.error("lut_parse_failed name=\(resourceName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func preload(preset: FilmPreset) {
        _ = try? loadCubeLUT(resourceName: preset.lutResourceName)
    }

    /// 从文件 URL 加载自定义 LUT（用于用户导入的 .cube 文件）
    @discardableResult
    func loadCubeLUTFromFile(url: URL, cacheKey: String) throws -> CubeLUT {
        if let cached = lock.withLock({ $0.lutCache[cacheKey] }) {
            return cached
        }
        do {
            let text = try Self.readCubeText(from: url)
            let cube = try Self.parseCubeFile(text)
            lock.withLock { $0.lutCache[cacheKey] = cube }
            return cube
        } catch {
            Log.lut.error("lut_custom_parse_failed key=\(cacheKey, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// 获取已缓存的 LUT 数据（用于 Metal 预览创建 3D 纹理）
    func getCachedLUT(cacheKey: String) -> CubeLUT? {
        lock.withLock { $0.lutCache[cacheKey] }
    }

    /// 预加载 FilmSource 对应的 LUT
    func preload(source: FilmSource) {
        switch source {
        case .preset(let p):
            preload(preset: p)
        case .custom(_, _, _, let fileName):
            let url = CustomLUT.storageDirectory.appendingPathComponent(fileName)
            _ = try? loadCubeLUTFromFile(url: url, cacheKey: source.lutCacheKey)
        }
    }

    /// 应用 LUT 并保留/添加元数据（拍照用，统一 sRGB 色彩空间）
    func applyLUTPreservingMetadata(imageData: Data, lutCacheKey: String, outputQuality: CGFloat = 0.95, location: CLLocation? = nil, focalLengthIn35mm: Int? = nil) -> Data? {
        // 读取原始 EXIF 方向（AVCapture 写入时通常为 6/3/8，像素保留在传感器原始横向朝向）
        let sourceProps: [String: Any]? = {
            guard let src = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
            return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        }()
        let exifOrientation: Int32 = {
            if let v = sourceProps?[kCGImagePropertyOrientation as String] as? Int32 { return v }
            if let v = sourceProps?[kCGImagePropertyOrientation as String] as? Int { return Int32(v) }
            if let v = sourceProps?[kCGImagePropertyOrientation as String] as? UInt32 { return Int32(v) }
            return 1
        }()

        guard let rawCI = CIImage(data: imageData) else {
            Log.lut.error("lut_apply_failed reason=ciimage_init_nil bytes=\(imageData.count)")
            return nil
        }
        let timer = Log.perf("lut_apply", logger: Log.lut)
        // 物理旋转像素到视觉正向朝向，这样 extent 反映真实宽高、输出 orientation=1 才正确
        var ciInput = rawCI.oriented(forExifOrientation: exifOrientation)

        let inputExtent = ciInput.extent
        let isLandscape = inputExtent.width > inputExtent.height
        Log.lut.info("lut_apply_begin key=\(lutCacheKey, privacy: .public) exif=\(exifOrientation) w=\(Int(inputExtent.width)) h=\(Int(inputExtent.height)) landscape=\(isLandscape)")

        // 根据照片方向裁剪为对应比例（横拍4:3，竖拍3:4）
        let targetAspect: CGFloat = isLandscape ? (4.0 / 3.0) : (3.0 / 4.0)
        let currentAspect = inputExtent.width / inputExtent.height

        if abs(currentAspect - targetAspect) > 0.01 {
            var cropRect = inputExtent
            if currentAspect > targetAspect {
                let newWidth = inputExtent.height * targetAspect
                let xOffset = (inputExtent.width - newWidth) / 2
                cropRect = CGRect(x: inputExtent.origin.x + xOffset, y: inputExtent.origin.y, width: newWidth, height: inputExtent.height)
            } else {
                let newHeight = inputExtent.width / targetAspect
                let yOffset = (inputExtent.height - newHeight) / 2
                cropRect = CGRect(x: inputExtent.origin.x, y: inputExtent.origin.y + yOffset, width: inputExtent.width, height: newHeight)
            }
            ciInput = ciInput.cropped(to: cropRect)
        }

        // 应用 LUT 滤镜（每次创建新 CIFilter，避免线程竞争）
        // 使用 CIColorCubeWithColorSpace 显式指定输入色彩空间为 sRGB，
        // 保证在 P3/HDR 源像素上应用 LUT 时的颜色一致性
        guard let colorCube = CIFilter(name: "CIColorCubeWithColorSpace"),
              let lut = getCachedLUT(cacheKey: lutCacheKey) else {
            Log.lut.error("lut_apply_failed reason=lut_missing key=\(lutCacheKey, privacy: .public)")
            return nil
        }

        colorCube.setValue(ciInput, forKey: kCIInputImageKey)
        colorCube.setValue(lut.dimension, forKey: "inputCubeDimension")
        colorCube.setValue(lut.data, forKey: "inputCubeData")
        colorCube.setValue(srgbColorSpace, forKey: "inputColorSpace")

        guard let output = colorCube.outputImage else { return nil }

        // 渲染为 JPEG（统一 sRGB）
        guard let renderedJPEG = ciContext.jpegRepresentation(
            of: output,
            colorSpace: srgbColorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: outputQuality]
        ) else { return nil }

        // 提取原始元数据
        guard let originalSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        var metadata = CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [String: Any] ?? [:]

        // 方向标记为 .up（像素已物理旋转）
        metadata[kCGImagePropertyOrientation as String] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }

        // 添加 GPS 信息
        if let loc = location {
            var gps: [String: Any] = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
            gps[kCGImagePropertyGPSLatitude as String] = abs(loc.coordinate.latitude)
            gps[kCGImagePropertyGPSLongitude as String] = abs(loc.coordinate.longitude)
            gps[kCGImagePropertyGPSLatitudeRef as String] = loc.coordinate.latitude >= 0 ? "N" : "S"
            gps[kCGImagePropertyGPSLongitudeRef as String] = loc.coordinate.longitude >= 0 ? "E" : "W"
            gps[kCGImagePropertyGPSAltitude as String] = abs(loc.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = loc.altitude >= 0 ? 0 : 1

            let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
            let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy:MM:dd"; dateFmt.timeZone = utc
            let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm:ss.SS"; timeFmt.timeZone = utc
            gps[kCGImagePropertyGPSDateStamp as String] = dateFmt.string(from: loc.timestamp)
            gps[kCGImagePropertyGPSTimeStamp as String] = timeFmt.string(from: loc.timestamp)

            if loc.speed >= 0 {
                gps[kCGImagePropertyGPSSpeed as String] = loc.speed * 3.6
                gps[kCGImagePropertyGPSSpeedRef as String] = "K"
            }
            if loc.course >= 0 {
                gps[kCGImagePropertyGPSImgDirection as String] = loc.course
                gps[kCGImagePropertyGPSImgDirectionRef as String] = "T"
            }
            metadata[kCGImagePropertyGPSDictionary as String] = gps
        }

        // 覆写等效焦距（EXIF：FocalLenIn35mmFilm）
        if let fl35 = focalLengthIn35mm {
            var exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = fl35
            metadata[kCGImagePropertyExifDictionary as String] = exif
        }

        // 写入最终图像
        guard let renderedSource = CGImageSourceCreateWithData(renderedJPEG as CFData, nil),
              let mutableData = CFDataCreateMutable(nil, 0),
              let imageType = CGImageSourceGetType(renderedSource),
              let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, nil) else {
            return nil
        }

        metadata[kCGImageDestinationLossyCompressionQuality as String] = outputQuality
        CGImageDestinationAddImageFromSource(destination, renderedSource, 0, metadata as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            Log.lut.error("lut_apply_failed reason=destination_finalize")
            return nil
        }
        let finalData = mutableData as Data
        timer.end("in=\(imageData.count)B out=\(finalData.count)B gps=\(location != nil)")
        return finalData
    }

}

// MARK: - 胶片包装卡片图鉴
//
// Resources/cards.json + Resources/cards/*.heic 共 550 张（去重后）。
// JSON 含 96 个品牌的元数据，所有可空字段均可能为 null。

struct FilmCard: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let image: String
    let brand: String?
    let product: String?
    let format: String?
    let iso: Int?
    let process: String?
    let expiry: String?
    let type: String?
    let subtype: String?
    let quantity: String?
    let notes: String?
    let author: String?
    /// 离线脚本（scripts/compute_card_colors.py）按主色粗略归类，10 桶之一：
    /// red / orange / yellow / green / blue / purple / brown / black / white / gray
    let color: String?
}

struct FilmCardBundle: Codable, Sendable {
    let version: Int
    let generatedAt: String
    let count: Int
    let imageSize: Int
    let cards: [FilmCard]
}

/// 卡片图像 NSCache + 磁盘下采样（与 ImageLoader 同模式，单独一份缓存避免互相挤占）
final class FilmCardImageCache: @unchecked Sendable {
    static let shared = FilmCardImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = 50 * 1024 * 1024
    }

    private func memoryCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 4096 }
        return max(cg.bytesPerRow * cg.height, 4096)
    }

    func cachedImage(cardId: String, maxPixel: Int) -> UIImage? {
        cache.object(forKey: "\(cardId)_\(maxPixel)" as NSString)
    }

    /// 异步下采样加载。命中缓存直接返回；否则在 detached 任务里用 CGImageSource 缩略图。
    func loadImage(card: FilmCard, maxPixel: Int) async -> UIImage? {
        let key = "\(card.id)_\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let cardId = card.id
        let imageName = card.image

        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return nil }

            let nameNoExt = (imageName as NSString).deletingPathExtension
            let ext = (imageName as NSString).pathExtension
            // Xcode 16 同步文件夹默认按 group 处理，资源会平铺到 bundle 根；
            // 但若被识别为 folder reference，则需要 subdirectory: "cards"。两种都尝试。
            let url = Bundle.main.url(forResource: nameNoExt, withExtension: ext)
                ?? Bundle.main.url(forResource: nameNoExt, withExtension: ext, subdirectory: "cards")
            guard let url else {
                Log.gallery.error("filmcard_image_missing id=\(cardId, privacy: .public) name=\(imageName, privacy: .public)")
                return nil
            }

            let opts: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else { return nil }
            let down: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 96),
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, down as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cg)
            self.cache.setObject(image, forKey: key, cost: self.memoryCost(of: image))
            return image
        }.value
    }
}

@MainActor
@Observable
final class FilmCardLibrary {
    static let shared = FilmCardLibrary()

    private(set) var all: [FilmCard] = []
    private(set) var byBrand: [String: [FilmCard]] = [:]
    /// 按卡片数量降序的品牌名（同数量按字母升序）
    private(set) var sortedBrands: [String] = []
    private(set) var isLoaded = false

    private init() {}

    /// 解析 cards.json 并构建索引（detached 解析，主 actor 写入状态）。
    func loadIfNeeded() async {
        guard !isLoaded else { return }

        let timer = Log.perf("filmcard_load", logger: Log.gallery)
        let parsed: FilmCardBundle? = await Task.detached(priority: .userInitiated) { () -> FilmCardBundle? in
            let url = Bundle.main.url(forResource: "cards", withExtension: "json")
                ?? Bundle.main.url(forResource: "cards", withExtension: "json", subdirectory: "cards")
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(FilmCardBundle.self, from: data)
        }.value

        guard let parsed else {
            Log.gallery.error("filmcard_bundle_missing")
            isLoaded = true
            timer.end("missing")
            return
        }

        let grouped = Dictionary(grouping: parsed.cards) { ($0.brand?.isEmpty == false ? $0.brand! : "未知品牌") }
        let brandOrder = grouped
            .map { ($0.key, $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.localizedCaseInsensitiveCompare(rhs.0) == .orderedAscending
            }
            .map { $0.0 }

        self.all = parsed.cards
        self.byBrand = grouped
        self.sortedBrands = brandOrder
        self.isLoaded = true
        timer.end("count=\(parsed.cards.count) brands=\(brandOrder.count)")
    }

    /// 异步加载下采样后的卡片图（命中 NSCache 直接返回）。
    func image(for card: FilmCard, maxPixel: Int = 300) async -> UIImage? {
        await FilmCardImageCache.shared.loadImage(card: card, maxPixel: maxPixel)
    }
}
