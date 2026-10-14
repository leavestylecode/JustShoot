import Foundation
import AVFoundation
import ImageIO

/// Only optical metadata and encoded dimensions leave this helper. In particular, the
/// complete metadata dictionary (including GPS and dates) is never formatted for logging.
enum CameraPhotoDiagnostics {
    nonisolated static func fields(imageData: Data, resolvedDimensions: CMVideoDimensions) -> String {
        let source = CGImageSourceCreateWithData(imageData as CFData, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [String: Any] ?? [:]
        return fields(properties: properties, resolvedDimensions: resolvedDimensions)
    }

    nonisolated static func fields(properties: [String: Any], resolvedDimensions: CMVideoDimensions) -> String {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        func numeric(_ key: CFString, in dictionary: [String: Any]) -> String {
            guard let value = dictionary[key as String] as? NSNumber, value.doubleValue.isFinite else { return "missing" }
            return String(format: "%.3f", value.doubleValue)
        }
        let physical = numeric(kCGImagePropertyExifFocalLength, in: exif)
        let equivalent = numeric(kCGImagePropertyExifFocalLenIn35mmFilm, in: exif)
        let orientation = numeric(kCGImagePropertyOrientation, in: properties)
        let lens = (exif[kCGImagePropertyExifLensModel as String] as? String).map {
            String($0.prefix(160)).components(separatedBy: .whitespacesAndNewlines).joined(separator: "_")
                .replacingOccurrences(of: "=", with: "_")
        } ?? "missing"
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue
        let resolution = width.flatMap { w in height.map { "\(w)x\($0)" } } ?? "missing"
        return "metadata_source=encoded_still physical_focal_mm=\(physical) original_equivalent_mm=\(equivalent) lens_model=\(lens) encoded_resolution=\(resolution) encoded_orientation=\(orientation) resolved_resolution=\(resolvedDimensions.width)x\(resolvedDimensions.height)"
    }
}
