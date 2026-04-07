import Foundation
import SwiftData
import UIKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation
import os

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
    @Relationship(inverse: \Roll.photos) var roll: Roll?
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
        filmPreset?.displayName ?? "默认"
    }
}

struct CubeLUT: Sendable {
    let data: Data
    let dimension: Int
}

// MARK: - 胶卷分组（27张一组）
@Model
final class Roll: Identifiable {
    var id: UUID
    var createdAt: Date
    var completedAt: Date?
    var presetName: String
    var capacity: Int
    @Relationship var photos: [Photo]

    init(preset: FilmPreset, capacity: Int = 27) {
        self.id = UUID()
        self.createdAt = Date()
        self.presetName = preset.rawValue
        self.capacity = capacity
        self.photos = []
    }

    var preset: FilmPreset? { FilmPreset(rawValue: presetName) }
    var displayName: String { preset?.displayName ?? presetName }
    var shotsTaken: Int { photos.count }
    var exposuresRemaining: Int { max(0, capacity - shotsTaken) }
    var isCompleted: Bool { completedAt != nil || shotsTaken >= capacity }
}

// MARK: - 胶片处理器（线程安全）
final class FilmProcessor: Sendable {
    static let shared = FilmProcessor()

    private let ciContext: CIContext
    /// 保护 lutCache 和 previewFilter 的锁
    private let lock = OSAllocatedUnfairLock<LUTState>(initialState: LUTState())

    /// 锁内保护的可变状态
    private struct LUTState {
        var lutCache: [String: CubeLUT] = [:]
        /// 预览用 CIFilter 缓存（避免每帧创建）
        var previewFilterCache: [String: CIFilter] = [:]
    }

    private init() {
        let srgbColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.ciContext = CIContext(options: [
            CIContextOption.useSoftwareRenderer: false,
            CIContextOption.workingColorSpace: srgbColorSpace,
            CIContextOption.outputColorSpace: srgbColorSpace
        ])
    }

    func loadCubeLUT(resourceName: String) throws -> CubeLUT {
        // 快速路径：缓存命中
        if let cached = lock.withLock({ $0.lutCache[resourceName] }) {
            return cached
        }

        // 慢路径：解析 LUT 文件（锁外执行，避免长时间持锁）
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "cube") else {
            throw NSError(domain: "FilmProcessor", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 LUT 资源: \(resourceName).cube"])
        }

        let text = try String(contentsOf: url, encoding: .utf8)
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
        let cube = CubeLUT(data: data, dimension: size)

        // 写入缓存（可能有并发写入，以最后一个为准，结果一致）
        lock.withLock { $0.lutCache[resourceName] = cube }
        return cube
    }

    func preload(preset: FilmPreset) {
        _ = try? loadCubeLUT(resourceName: preset.lutResourceName)
    }

    /// 应用 LUT 并保留/添加元数据（拍照用，统一 sRGB 色彩空间）
    func applyLUTPreservingMetadata(imageData: Data, preset: FilmPreset, outputQuality: CGFloat = 0.95, location: CLLocation? = nil) -> Data? {
        guard var ciInput = CIImage(data: imageData) else {
            print("❌ [LUT] 无法从数据创建 CIImage")
            return nil
        }

        let inputExtent = ciInput.extent
        let isLandscape = inputExtent.width > inputExtent.height

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

        // 应用 LUT 滤镜
        guard let colorCube = CIFilter(name: "CIColorCube") else { return nil }

        do {
            let lut = try loadCubeLUT(resourceName: preset.lutResourceName)
            colorCube.setValue(ciInput, forKey: kCIInputImageKey)
            colorCube.setValue(lut.dimension, forKey: "inputCubeDimension")
            colorCube.setValue(lut.data, forKey: "inputCubeData")
        } catch {
            print("❌ [LUT] 加载 LUT 失败: \(error)")
            return nil
        }

        guard let output = colorCube.outputImage else { return nil }

        // 渲染为 JPEG（统一 sRGB）
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let renderedJPEG = ciContext.jpegRepresentation(
            of: output,
            colorSpace: colorSpace,
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

            let utc = TimeZone(secondsFromGMT: 0)!
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

        // 写入最终图像
        guard let renderedSource = CGImageSourceCreateWithData(renderedJPEG as CFData, nil),
              let mutableData = CFDataCreateMutable(nil, 0),
              let imageType = CGImageSourceGetType(renderedSource),
              let destination = CGImageDestinationCreateWithData(mutableData, imageType, 1, nil) else {
            return nil
        }

        metadata[kCGImageDestinationLossyCompressionQuality as String] = outputQuality
        CGImageDestinationAddImageFromSource(destination, renderedSource, 0, metadata as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// 实时预览：对 CIImage 应用 LUT，复用缓存的 CIFilter（避免每帧创建）
    func applyLUT(to image: CIImage, preset: FilmPreset) -> CIImage? {
        let resourceName = preset.lutResourceName

        // 获取或创建 filter + lut 数据
        let (filter, lut): (CIFilter, CubeLUT) = lock.withLock { state in
            let cachedLUT = state.lutCache[resourceName]
            let cachedFilter = state.previewFilterCache[resourceName]

            if let f = cachedFilter, let l = cachedLUT {
                return (f, l)
            }

            // 需要创建 filter
            let f = cachedFilter ?? CIFilter(name: "CIColorCube")!
            let l: CubeLUT
            if let cl = cachedLUT {
                l = cl
            } else {
                // LUT 未加载（不应发生，因为有 preload）
                guard let loaded = try? self.loadCubeLUTUnsafe(resourceName: resourceName) else {
                    return (f, CubeLUT(data: Data(), dimension: 0))
                }
                state.lutCache[resourceName] = loaded
                l = loaded
            }

            f.setValue(l.dimension, forKey: "inputCubeDimension")
            f.setValue(l.data, forKey: "inputCubeData")
            state.previewFilterCache[resourceName] = f
            return (f, l)
        }

        guard lut.dimension > 0 else { return nil }

        // 只更新 inputImage（dimension 和 cubeData 已缓存在 filter 中）
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    /// 锁内调用的 LUT 加载（不获取锁）
    private func loadCubeLUTUnsafe(resourceName: String) throws -> CubeLUT {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "cube") else {
            throw NSError(domain: "FilmProcessor", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 LUT 资源: \(resourceName).cube"])
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        lines.removeAll { $0.hasPrefix("#") || $0.isEmpty }

        var size = 0
        var values: [Float] = []
        for line in lines {
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                if let last = line.split(separator: " ").last, let dim = Int(last) { size = dim }
            } else {
                let comps = line.split(separator: " ").compactMap { Float($0) }
                if comps.count == 3 { values.append(contentsOf: comps) }
            }
        }
        guard size > 0, values.count == size * size * size * 3 else {
            throw NSError(domain: "FilmProcessor", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "LUT 解析失败或尺寸不匹配"])
        }
        var rgba: [Float] = []
        rgba.reserveCapacity(size * size * size * 4)
        for i in stride(from: 0, to: values.count, by: 3) {
            rgba.append(values[i]); rgba.append(values[i + 1]); rgba.append(values[i + 2]); rgba.append(1.0)
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(data: data, dimension: size)
    }
}
