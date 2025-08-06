import Foundation
import SwiftData
import UIKit
import ImageIO

@Model
final class Photo: Identifiable {
    var id: UUID
    var timestamp: Date
    var imageData: Data
    
    init(imageData: Data) {
        self.id = UUID()
        self.timestamp = Date()
        self.imageData = imageData
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
        guard let exif = exifData?[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double else {
            return "未知"
        }
        return String(format: "%.0fmm", focal)
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