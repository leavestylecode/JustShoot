import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import JustShoot

final class CameraPhotoDiagnosticsTests: XCTestCase {
    func testEncodedStillReportsOriginalOpticsAndEncodedSizeWithoutGPS() throws {
        let pixels = Data(repeating: 128, count: 8)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFocalLength as String: 6.76,
                kCGImagePropertyExifFocalLenIn35mmFilm as String: 24,
                kCGImagePropertyExifLensModel as String: "Back wide camera"
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 31.2345,
                kCGImagePropertyGPSLongitude as String: 121.5432
            ]
        ]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let fields = CameraPhotoDiagnostics.fields(imageData: data as Data,
            resolvedDimensions: CMVideoDimensions(width: 5712, height: 4284))
        XCTAssertTrue(fields.contains("physical_focal_mm=6.760"))
        XCTAssertTrue(fields.contains("original_equivalent_mm=24.000"))
        XCTAssertTrue(fields.contains("lens_model=Back_wide_camera"))
        XCTAssertTrue(fields.contains("encoded_resolution=2x1"))
        XCTAssertTrue(fields.contains("resolved_resolution=5712x4284"))
        XCTAssertFalse(fields.contains("31.2345"))
        XCTAssertFalse(fields.contains("121.5432"))
        XCTAssertFalse(fields.contains("GPS"))
    }
}
