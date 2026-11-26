import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    var fileFormat: String?
    var exposureBias: String?
    var lensModel: String?

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
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return .empty }
        return parse(from: source)
    }

    static func parse(from imageSource: CGImageSource) -> ParsedExifInfo {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
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
            guard model != unknownString || make != unknownString else { return nil }
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
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            fileFormat: CGImageSourceGetType(imageSource).flatMap { UTType($0 as String)?.preferredFilenameExtension?.uppercased() },
            exposureBias: (exif?[kCGImagePropertyExifExposureBiasValue as String] as? NSNumber).map {
                $0.doubleValue.formatted(.number.precision(.fractionLength(0...2))) + " EV"
            },
            lensModel: exif?[kCGImagePropertyExifLensModel as String] as? String
        )
    }
}
