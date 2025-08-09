import Foundation
import SwiftData
import UIKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation

@Model
final class Photo: Identifiable {
    var id: UUID
    var timestamp: Date
    @Attribute(.externalStorage) var imageData: Data
    var filmPresetName: String?
    @Relationship(inverse: \Roll.photos) var roll: Roll?
    // 位置信息（用于相册保存时同步到 PHAsset.location）
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var locationTimestamp: Date?
    
    init(imageData: Data, filmPresetName: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.imageData = imageData
        self.filmPresetName = filmPresetName
    }
    
    var image: UIImage? {
        return UIImage(data: imageData)
    }
    
    // EXIF 数据提取
    var exifData: [String: Any]? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return nil
        }
        return properties
    }
    
    // 获取特定的EXIF信息
    var iso: String {
        guard let exif = exifData?[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let isoValue = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
              let iso = isoValue.first else {
            return "未知"
        }
        return "ISO \(iso)"
    }
    
    var shutterSpeed: String {
        guard let exif = exifData?[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double else {
            return "未知"
        }
        
        if exposureTime >= 1 {
            return String(format: "%.1fs", exposureTime)
        } else {
            return "1/\(Int(1/exposureTime))s"
        }
    }
    
    var aperture: String {
        guard let exif = exifData?[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double else {
            return "未知"
        }
        return String(format: "f/%.1f", fNumber)
    }
    
    var focalLength: String {
        guard let exif = exifData?[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            return "未知"
        }
        
        // 优先使用35mm等效焦距
        if let focalLength35mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int {
            return "\(focalLength35mm)mm"
        }
        
        // 如果没有35mm等效焦距，使用实际物理焦距
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            return String(format: "%.0fmm", focal)
        }
        
        return "未知"
    }
    
    var exposureMode: String {
        guard let exif = exifData?[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let exposureMode = exif[kCGImagePropertyExifExposureMode as String] as? Int else {
            return "未知"
        }
        
        switch exposureMode {
        case 0: return "自动曝光"
        case 1: return "手动曝光"
        case 2: return "自动包围曝光"
        default: return "未知"
        }
    }
    
    var flashMode: String {
        guard let exif = exifData?[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let flash = exif[kCGImagePropertyExifFlash as String] as? Int else {
            return "未知"
        }
        
        if flash & 0x01 != 0 {
            return "闪光灯开启"
        } else {
            return "闪光灯关闭"
        }
    }
    
    // GPS信息
    var gpsInfo: (latitude: String, longitude: String, altitude: String)? {
        guard let gpsDict = exifData?[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              let lat = gpsDict[kCGImagePropertyGPSLatitude as String] as? Double,
              let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef as String] as? String,
              let lon = gpsDict[kCGImagePropertyGPSLongitude as String] as? Double,
              let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef as String] as? String else {
            return nil
        }
        
        let altitude = gpsDict[kCGImagePropertyGPSAltitude as String] as? Double ?? 0
        
        return (
            latitude: String(format: "%.6f°%@", lat, latRef),
            longitude: String(format: "%.6f°%@", lon, lonRef),
            altitude: String(format: "%.1fm", altitude)
        )
    }
    
    // 设备信息
    var deviceInfo: (make: String, model: String, software: String)? {
        let tiffDict = exifData?[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        
        let make = tiffDict?[kCGImagePropertyTIFFMake as String] as? String ?? "未知"
        let model = tiffDict?[kCGImagePropertyTIFFModel as String] as? String ?? "未知"
        let software = tiffDict?[kCGImagePropertyTIFFSoftware as String] as? String ?? "未知"
        
        return (make: make, model: model, software: software)
    }
    
    // 镜头信息
    var lensInfo: String {
        guard let exif = exifData?[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
            return "未知镜头"
        }
        
        // 尝试从不同的EXIF字段获取镜头信息
        if let lensModel = exif["LensModel"] as? String {
            return lensModel
        }
        
        if let lensMake = exif["LensMake"] as? String {
            return lensMake
        }
        
        // 如果没有专门的镜头信息，返回相机型号作为镜头信息
        if let deviceInfo = deviceInfo {
            return "\(deviceInfo.make) \(deviceInfo.model) 内置镜头"
        }
        
        return "内置镜头"
    }
} 

// MARK: - 胶片预设与处理
enum FilmPreset: String, CaseIterable, Identifiable, Sendable {
    case fujiC200
    case fujiPro400H
    case fujiProvia100F
    case kodakPortra400
    case kodakVision5219 // 500T
    case kodakVision5203 // 50D
    case kodak5207       // 250D（文件名无 Vision 前缀）
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

    // 资源文件名（不含扩展名）
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

struct CubeLUT {
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

final class FilmProcessor {
    static let shared = FilmProcessor()

    private let ciContext: CIContext
    private var lutCache: [String: CubeLUT] = [:]

    private init() {
        // 使用 Metal 后端的 CIContext 以获得更好性能
        self.ciContext = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
    }

    func loadCubeLUT(resourceName: String) throws -> CubeLUT {
        if let cached = lutCache[resourceName] { return cached }

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "cube") else {
            throw NSError(domain: "FilmProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "找不到 LUT 资源: \(resourceName).cube"])
        }

        let text = try String(contentsOf: url)
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
                // 粗略判断是否为数值行
                let comps = line.split(separator: " ").compactMap { Float($0) }
                if comps.count == 3 {
                    values.append(contentsOf: comps)
                }
            }
        }

        guard size > 0, values.count == size * size * size * 3 else {
            throw NSError(domain: "FilmProcessor", code: -2, userInfo: [NSLocalizedDescriptionKey: "LUT 解析失败或尺寸不匹配"])
        }

        var rgba: [Float] = []
        rgba.reserveCapacity(size * size * size * 4)
        for i in stride(from: 0, to: values.count, by: 3) {
            rgba.append(values[i + 0])
            rgba.append(values[i + 1])
            rgba.append(values[i + 2])
            rgba.append(1.0)
        }

        // 安全构造 Data，避免悬垂指针
        let data: Data = rgba.withUnsafeBufferPointer { buffer in
            return Data(buffer: buffer)
        }
        let cube = CubeLUT(
            data: data,
            dimension: size
        )
        lutCache[resourceName] = cube
        return cube
    }

    // 预加载（放到缓存），减少首次拍摄开销
    func preload(preset: FilmPreset) {
        _ = try? loadCubeLUT(resourceName: preset.lutResourceName)
    }

    func applyLUT(to inputData: Data, preset: FilmPreset, outputQuality: CGFloat = 0.95) -> Data? {
        guard let ciInput = CIImage(data: inputData) else { return nil }
        guard let colorCube = CIFilter(name: "CIColorCube") else { return nil }

        do {
            let lut = try loadCubeLUT(resourceName: preset.lutResourceName)
            colorCube.setValue(ciInput, forKey: kCIInputImageKey)
            colorCube.setValue(lut.dimension, forKey: "inputCubeDimension")
            colorCube.setValue(lut.data, forKey: "inputCubeData")
        } catch {
            return nil
        }

        guard let output = colorCube.outputImage else { return nil }

        // 渲染为 JPEG 数据
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        if let data = ciContext.jpegRepresentation(of: output, colorSpace: colorSpace, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: outputQuality]) {
            return data as Data
        }
        return nil
    }

    // 应用 LUT 并尽量保留原图元数据（EXIF/GPS/方向等）
    func applyLUTPreservingMetadata(imageData: Data, preset: FilmPreset, outputQuality: CGFloat = 0.95, location: CLLocation? = nil) -> Data? {
        guard let ciInput = CIImage(data: imageData) else { return nil }
        guard let colorCube = CIFilter(name: "CIColorCube") else { return nil }
        do {
            let lut = try loadCubeLUT(resourceName: preset.lutResourceName)
            colorCube.setValue(ciInput, forKey: kCIInputImageKey)
            colorCube.setValue(lut.dimension, forKey: "inputCubeDimension")
            colorCube.setValue(lut.data, forKey: "inputCubeData")
        } catch {
            return nil
        }

        guard let output = colorCube.outputImage else { return nil }

        // 用 JPEG 表示以减少内存占用，然后用 CGImageDestination 复制元数据
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let renderedJPEG = ciContext.jpegRepresentation(
            of: output,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: outputQuality]
        ) else { return nil }

        // 原图元数据（延迟到后台做，不阻塞快门返回）
        guard let originalSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        var originalMetadata = CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [String: Any] ?? [:]

        // 将渲染后的 JPEG 作为 source，再写出附带原元数据
        guard let renderedSource = CGImageSourceCreateWithData(renderedJPEG as CFData, nil) else { return nil }
        guard let mutableData = CFDataCreateMutable(nil, 0) else { return nil }
        let imageType = CGImageSourceGetType(renderedSource) ?? CGImageSourceGetType(originalSource)
        guard let destination = CGImageDestinationCreateWithData(mutableData, imageType!, 1, nil) else { return nil }

        // 合并 GPS 信息（如有需要始终写入）
        if let loc = location {
            var gps: [String: Any] = originalMetadata[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
            // 坐标与参考方向
            gps[kCGImagePropertyGPSLatitude as String] = abs(loc.coordinate.latitude)
            gps[kCGImagePropertyGPSLongitude as String] = abs(loc.coordinate.longitude)
            gps[kCGImagePropertyGPSLatitudeRef as String] = loc.coordinate.latitude >= 0 ? "N" : "S"
            gps[kCGImagePropertyGPSLongitudeRef as String] = loc.coordinate.longitude >= 0 ? "E" : "W"
            // 海拔与参考（0=海平面以上，1=以下）
            gps[kCGImagePropertyGPSAltitude as String] = abs(loc.altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = loc.altitude >= 0 ? 0 : 1
            // 时间（UTC）：分别提供 DateStamp 与 TimeStamp，兼容 Photos/EXIF 读取
            let utc = TimeZone(secondsFromGMT: 0)
            let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy:MM:dd"; dateFmt.timeZone = utc
            let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm:ss.SS"; timeFmt.timeZone = utc
            gps[kCGImagePropertyGPSDateStamp as String] = dateFmt.string(from: loc.timestamp)
            gps[kCGImagePropertyGPSTimeStamp as String] = timeFmt.string(from: loc.timestamp)
            // 速度（转换为 km/h）与参考单位
            if loc.speed >= 0 {
                let kmh = loc.speed * 3.6
                gps[kCGImagePropertyGPSSpeed as String] = kmh
                gps[kCGImagePropertyGPSSpeedRef as String] = "K" // km/h
            }
            // 航向与参考（真北）
            if loc.course >= 0 {
                gps[kCGImagePropertyGPSImgDirection as String] = loc.course
                gps[kCGImagePropertyGPSImgDirectionRef as String] = "T"
            }
            originalMetadata[kCGImagePropertyGPSDictionary as String] = gps
        }

        let finalMetadata = originalMetadata
        // 写入时同时传入压缩质量，避免后续修改目的地属性导致报错
        var props = finalMetadata
        props[kCGImageDestinationLossyCompressionQuality as String] = outputQuality
        CGImageDestinationAddImageFromSource(destination, renderedSource, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    // 实时预览：对 CIImage 直接应用 LUT，返回 CIImage（用于 GPU 管线）
    func applyLUT(to image: CIImage, preset: FilmPreset) -> CIImage? {
        guard let colorCube = CIFilter(name: "CIColorCube") else { return nil }
        do {
            let lut = try loadCubeLUT(resourceName: preset.lutResourceName)
            colorCube.setValue(image, forKey: kCIInputImageKey)
            colorCube.setValue(lut.dimension, forKey: "inputCubeDimension")
            colorCube.setValue(lut.data, forKey: "inputCubeData")
            return colorCube.outputImage
        } catch {
            return nil
        }
    }
}