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
        // 仅在拍后进行完整的胶片模拟管线（不影响实时预览性能）
        let output = processFinalCI(ciInput, preset: preset)

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

    // MARK: - 拍后最终处理管线（不影响预览）
    private func processFinalCI(_ image: CIImage, preset: FilmPreset) -> CIImage {
        // 1) LUT（色彩基线）
        let lutApplied = applyLUT(to: image, preset: preset) ?? image

        // 预设参数（适中强度，后续可微调）
        let tone: (CIVector, CIVector, CIVector, CIVector, CIVector)
        let bloomRadius: CGFloat
        let bloomIntensity: CGFloat
        let halationRadius: CGFloat
        let halationIntensity: CGFloat
        // 去掉渐晕相关参数
        // 去掉桶形/色散
        let colorMatrix: (CIVector, CIVector, CIVector, CIVector)
        // 颗粒统一模拟 ISO 400（固定强度/尺度），不随预设变化
        let iso400GrainLuma: CGFloat = 0.14
        let iso400GrainChroma: CGFloat = 0.08
        let iso400GrainScale: CGFloat = 1.8

        switch preset {
        case .fujiC200:
            tone = (
                CIVector(x: 0.0, y: 0.0),
                CIVector(x: 0.25, y: 0.22),
                CIVector(x: 0.5, y: 0.5),
                CIVector(x: 0.75, y: 0.85),
                CIVector(x: 1.0, y: 1.0)
            )
            bloomRadius = 14; bloomIntensity = 0.18
            halationRadius = 18; halationIntensity = 0.10
            
            colorMatrix = (
                CIVector(x: 0.98, y: 0.02, z: 0.0, w: 0),
                CIVector(x: 0.02, y: 0.98, z: 0.0, w: 0),
                CIVector(x: 0.00, y: 0.02, z: 0.98, w: 0),
                CIVector(x: 0, y: 0, z: 0, w: 0)
            )
            // no paper/scan; grain fixed to ISO400
        case .fujiPro400H:
            tone = (
                CIVector(x: 0.0, y: 0.02),
                CIVector(x: 0.25, y: 0.28),
                CIVector(x: 0.5, y: 0.55),
                CIVector(x: 0.75, y: 0.82),
                CIVector(x: 1.0, y: 0.98)
            )
            bloomRadius = 15; bloomIntensity = 0.16
            halationRadius = 16; halationIntensity = 0.08
            
            colorMatrix = (
                CIVector(x: 1.02, y: 0.02, z: 0.0, w: 0),
                CIVector(x: 0.01, y: 0.99, z: 0.0, w: 0),
                CIVector(x: 0.00, y: 0.02, z: 0.98, w: 0),
                CIVector(x: 0, y: 0, z: 0, w: 0)
            )
            // no paper/scan; grain fixed to ISO400
        case .fujiProvia100F:
            tone = (
                CIVector(x: 0.0, y: 0.0),
                CIVector(x: 0.25, y: 0.18),
                CIVector(x: 0.5, y: 0.5),
                CIVector(x: 0.75, y: 0.92),
                CIVector(x: 1.0, y: 1.0)
            )
            bloomRadius = 10; bloomIntensity = 0.10
            halationRadius = 10; halationIntensity = 0.05
            
            colorMatrix = (
                CIVector(x: 1.02, y: 0.0, z: 0.0, w: 0),
                CIVector(x: 0.0, y: 1.02, z: 0.0, w: 0),
                CIVector(x: 0.0, y: 0.0, z: 1.02, w: 0),
                CIVector(x: 0, y: 0, z: 0, w: 0)
            )
            // no paper/scan; grain fixed to ISO400
        case .kodakPortra400:
            tone = (
                CIVector(x: 0.0, y: 0.02),
                CIVector(x: 0.25, y: 0.24),
                CIVector(x: 0.5, y: 0.54),
                CIVector(x: 0.75, y: 0.88),
                CIVector(x: 1.0, y: 0.98)
            )
            bloomRadius = 18; bloomIntensity = 0.22
            halationRadius = 22; halationIntensity = 0.12
            
            colorMatrix = (
                CIVector(x: 1.03, y: 0.02, z: 0.0, w: 0),
                CIVector(x: 0.00, y: 0.98, z: 0.0, w: 0),
                CIVector(x: 0.00, y: 0.02, z: 0.97, w: 0),
                CIVector(x: 0, y: 0, z: 0, w: 0)
            )
            // no paper/scan; grain fixed to ISO400
        case .kodakVision5219:
            tone = (
                CIVector(x: 0.0, y: 0.02),
                CIVector(x: 0.25, y: 0.27),
                CIVector(x: 0.5, y: 0.55),
                CIVector(x: 0.75, y: 0.86),
                CIVector(x: 1.0, y: 0.98)
            )
            bloomRadius = 20; bloomIntensity = 0.20
            halationRadius = 26; halationIntensity = 0.14
            
            colorMatrix = (
                CIVector(x: 1.0, y: 0.01, z: 0.0, w: 0),
                CIVector(x: 0.0, y: 1.0, z: 0.01, w: 0),
                CIVector(x: 0.01, y: 0.0, z: 1.0, w: 0),
                CIVector(x: 0, y: 0, z: 0, w: 0)
            )
            // no paper/scan; grain fixed to ISO400
        case .kodakVision5203:
            tone = (
                CIVector(x: 0.0, y: 0.0),
                CIVector(x: 0.25, y: 0.26),
                CIVector(x: 0.5, y: 0.55),
                CIVector(x: 0.75, y: 0.90),
                CIVector(x: 1.0, y: 1.0)
            )
            bloomRadius = 12; bloomIntensity = 0.12
            halationRadius = 14; halationIntensity = 0.08
            
            colorMatrix = (
                CIVector(x: 1.0, y: 0.01, z: 0.0, w: 0),
                CIVector(x: 0.0, y: 1.0, z: 0.01, w: 0),
                CIVector(x: 0.01, y: 0.0, z: 1.0, w: 0),
                CIVector(x: 0, y: 0, z: 0, w: 0)
            )
            // no paper/scan; grain fixed to ISO400
        case .kodak5207:
            tone = (
                CIVector(x: 0.0, y: 0.0),
                CIVector(x: 0.25, y: 0.26),
                CIVector(x: 0.5, y: 0.55),
                CIVector(x: 0.75, y: 0.90),
                CIVector(x: 1.0, y: 1.0)
            )
            bloomRadius = 14; bloomIntensity = 0.14
            halationRadius = 18; halationIntensity = 0.10
            
            colorMatrix = (
                CIVector(x: 1.0, y: 0.01, z: 0.0, w: 0),
                CIVector(x: 0.0, y: 1.0, z: 0.01, w: 0),
                CIVector(x: 0.01, y: 0.0, z: 1.0, w: 0),
                CIVector(x: 0, y: 0, z: 0, w: 0)
            )
            // no paper/scan; grain fixed to ISO400
        case .harmanPhoenix200:
            tone = (
                CIVector(x: 0.0, y: 0.0),
                CIVector(x: 0.25, y: 0.18),
                CIVector(x: 0.5, y: 0.5),
                CIVector(x: 0.75, y: 0.92),
                CIVector(x: 1.0, y: 1.0)
            )
            bloomRadius = 14; bloomIntensity = 0.16
            halationRadius = 18; halationIntensity = 0.09
            
            colorMatrix = (
                CIVector(x: 0.98, y: 0.02, z: 0.0, w: 0),
                CIVector(x: 0.0, y: 1.0, z: 0.02, w: 0),
                CIVector(x: 0.02, y: 0.02, z: 1.0, w: 0),
                CIVector(x: 0, y: 0, z: 0, w: 0)
            )
            // no paper/scan; grain fixed to ISO400
        }

        // 2) Tone Curve（Toe/Shoulder）
//        let curved = applyingToneCurve(lutApplied, points: tone)
//
//        // 3) Bloom（高光泛光）
//        let bloomed = applyingBloom(curved, radius: bloomRadius, intensity: bloomIntensity)
//
//        // 4) Halation（红晕）：红通道加权 + Screen 叠加
//        let halated = applyingHalation(bloomed, radius: halationRadius, intensity: halationIntensity)
//
//        // 5) 色彩矩阵（轻微串扰）
//        let colored = applyingColorMatrix(halated, r: colorMatrix.0, g: colorMatrix.1, b: colorMatrix.2, bias: colorMatrix.3)
//
        // 6) 去掉渐晕，直接进入颗粒
        // 颗粒（统一 ISO400 模拟）
        let grained = applyingGrain(lutApplied, luma: iso400GrainLuma, chroma: iso400GrainChroma, scale: iso400GrainScale)

        // 9) 漏光（低概率、轻强度）
        let final = applyingLightLeak(grained, probability: 0.05, intensity: 0.08)
        return final
    }

    // MARK: - 算子实现（拍后）
    private func applyingToneCurve(_ image: CIImage, points: (CIVector, CIVector, CIVector, CIVector, CIVector)) -> CIImage {
        guard let f = CIFilter(name: "CIToneCurve") else { return image }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(points.0, forKey: "inputPoint0")
        f.setValue(points.1, forKey: "inputPoint1")
        f.setValue(points.2, forKey: "inputPoint2")
        f.setValue(points.3, forKey: "inputPoint3")
        f.setValue(points.4, forKey: "inputPoint4")
        return f.outputImage ?? image
    }

    private func applyingBloom(_ image: CIImage, radius: CGFloat, intensity: CGFloat) -> CIImage {
        let f = CIFilter.bloom()
        f.inputImage = image
        f.radius = Float(max(0, radius))
        f.intensity = Float(max(0, intensity))
        return f.outputImage ?? image
    }

    private func applyingHalation(_ image: CIImage, radius: CGFloat, intensity: CGFloat) -> CIImage {
        guard intensity > 0.001 else { return image }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image
        blur.radius = Float(max(0, radius))
        let blurred = blur.outputImage ?? image

        let tint = CIFilter.colorMatrix()
        tint.inputImage = blurred
        tint.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0.1, y: 0.1, z: 0.0, w: 0)
        tint.bVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 0)
        let tintedBase = tint.outputImage ?? blurred
        let tinted = tintedBase.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: intensity, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: intensity * 0.25, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let blend = CIFilter.screenBlendMode()
        blend.inputImage = tinted
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }

    private func applyingColorMatrix(_ image: CIImage, r: CIVector, g: CIVector, b: CIVector, bias: CIVector) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = r
        f.gVector = g
        f.bVector = b
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = bias
        return f.outputImage ?? image
    }

    private func applyingLensDefects(_ image: CIImage, barrelScale: CGFloat, barrelRadiusFactor: CGFloat, chromaShift: CGFloat) -> CIImage {
        var out = image
        if abs(barrelScale) > 0.001, let f = CIFilter(name: "CIBumpDistortion") {
            f.setValue(out, forKey: kCIInputImageKey)
            let extent = out.extent
            f.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: kCIInputCenterKey)
            f.setValue(max(10, min(extent.width, extent.height) * barrelRadiusFactor), forKey: kCIInputRadiusKey)
            f.setValue(barrelScale, forKey: kCIInputScaleKey)
            out = f.outputImage ?? out
        }
        if chromaShift > 0.001 {
            let r = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ]).transformed(by: CGAffineTransform(translationX: chromaShift, y: 0))
            let g = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
            let b = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0)
            ]).transformed(by: CGAffineTransform(translationX: -chromaShift, y: 0))
            if let addRB = CIFilter(name: "CIAdditionCompositing", parameters: [kCIInputImageKey: r, kCIInputBackgroundImageKey: b])?.outputImage,
               let addRGB = CIFilter(name: "CIAdditionCompositing", parameters: [kCIInputImageKey: addRB, kCIInputBackgroundImageKey: g])?.outputImage {
                out = addRGB
            }
        }
        return out
    }

    private func applyingVignette(_ image: CIImage, intensity: CGFloat, radius: CGFloat) -> CIImage {
        let f = CIFilter.vignette()
        f.inputImage = image
        f.intensity = Float(intensity)
        f.radius = Float(max(0.1, radius) * 200)
        return f.outputImage ?? image
    }

    private func applyingGrain(_ image: CIImage, luma: CGFloat, chroma: CGFloat, scale: CGFloat) -> CIImage {
        guard luma > 0.001 || chroma > 0.001 else { return image }

        // 1) 生成噪声并调整尺度
        let base = CIFilter.randomGenerator().outputImage ?? image
        let noise = base.transformed(by: CGAffineTransform(scaleX: 1.0 / max(0.6, scale), y: 1.0 / max(0.6, scale)))

        // 2) 生成亮度掩模（阴影更强，高光更弱）
        // 采用 ColorControls 降低对比并偏亮，随后取反得到 shadowMask
        let lumaImage = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputBrightnessKey: 0.0,
            kCIInputContrastKey: 0.9
        ])
        // 归一化到 0..1 后取反：shadowMask = 1 - normalized(luma)
        let inverted = lumaImage.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)
        ])
        // 软阈处理，避免亮部完全无粒
        let shadowMask = inverted.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.2])

        // 3) 构造颗粒贴图（明度颗粒 + 彩色细颗粒）
        let mono = noise.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let monoScaled = mono.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: luma, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: luma, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: luma, w: 0)
        ])
        let chromaScaled = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: chroma, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: chroma * 0.8, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: chroma * 0.7, w: 0)
        ])
        let combined = CIFilter.additionCompositing()
        combined.inputImage = monoScaled
        combined.backgroundImage = chromaScaled
        let grainRGB = combined.outputImage ?? monoScaled

        // 4) 用阴影掩模限制颗粒，仅在阴影/中暗区域明显
        // 先把掩模作为 alpha 叠到颗粒
        let maskedGrain = grainRGB.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
            kCIInputMaskImageKey: shadowMask
        ])

        // 5) 与原图以 SoftLight 叠加
        let soft = CIFilter.softLightBlendMode()
        soft.inputImage = maskedGrain.cropped(to: image.extent)
        soft.backgroundImage = image
        return soft.outputImage ?? image
    }

    private func applyingPaperScan(_ image: CIImage, warmth: CGFloat, tint: CGFloat, contrast: CGFloat, sharpen: CGFloat) -> CIImage {
        var out = image
        if let f = CIFilter(name: "CITemperatureAndTint") {
            f.setValue(out, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500 + warmth, y: tint), forKey: "inputTargetNeutral")
            out = f.outputImage ?? out
        }
        out = out.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: contrast])
        let sharp = CIFilter.sharpenLuminance()
        sharp.inputImage = out
        sharp.sharpness = Float(max(0, sharpen))
        out = sharp.outputImage ?? out
        return out
    }

    private func applyingLightLeak(_ image: CIImage, probability: CGFloat, intensity: CGFloat) -> CIImage {
        guard intensity > 0.001 else { return image }
        if CGFloat.random(in: 0...1) > probability { return image }
        let extent = image.extent
        let centerX = Bool.random() ? extent.minX : extent.maxX
        let center = CIVector(x: centerX, y: extent.midY)
        let radius0: CGFloat = min(extent.width, extent.height) * 0.1
        let radius1: CGFloat = min(extent.width, extent.height) * 0.8
        if let grad = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": center,
            "inputRadius0": radius0,
            "inputRadius1": radius1,
            "inputColor0": CIColor(red: 1.0, green: 0.35, blue: 0.1, alpha: intensity),
            "inputColor1": CIColor(red: 1, green: 0.35, blue: 0.1, alpha: 0)
        ])?.outputImage {
            let leak = grad.cropped(to: extent)
            let blend = CIFilter.screenBlendMode()
            blend.inputImage = leak
            blend.backgroundImage = image
            return blend.outputImage ?? image
        }
        return image
    }
}
