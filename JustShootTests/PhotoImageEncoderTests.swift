import XCTest
import CoreImage
import ImageIO
import Metal
@testable import JustShoot

final class PhotoImageEncoderTests: XCTestCase {
    func testAutomaticEncodingReducesSizeWhileKeepingPixelsMetadataAndDetail() async throws {
        // Prepare pixels and encode on a utility worker, matching the production pipeline.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .utility).async(qos: .utility, flags: [.enforceQoS, .detached]) {
                do {
                    try Self.verifyAutomaticEncoding()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func verifyAutomaticEncoding() throws {
        let width = 768, height = 576
        let colorSpace = FilmImagePipeline.colorSpace
        var pixels = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let ramp = 0.15 + 0.70 * Float(x) / Float(width - 1)
                let fine = 0.025 * sin(Float(x) * 1.17 + Float(y) * 2.34)
                let index = (y * width + x) * 4
                pixels[index] = ramp + fine
                pixels[index + 1] = ramp + fine * 0.9
                pixels[index + 2] = ramp + fine * 0.8
            }
        }
        let input = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: input, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: colorSpace)
            .settingProperties([
                kCGImagePropertyOrientation as String: 1,
                kCGImagePropertyExifDictionary as String: [
                    kCGImagePropertyExifDateTimeOriginal as String: "2026:10:14 12:34:56"
                ],
                kCGImagePropertyMakerAppleDictionary as String: ["17": "12345678-1234-1234-1234-123456789ABC"]
            ])
        let context = makeContext()
        let automatic = try XCTUnwrap(PhotoImageEncoder.encode(image, context: context, colorSpace: colorSpace))
        let legacy = try XCTUnwrap(PhotoImageEncoder.encode(image, context: context, colorSpace: colorSpace,
            legacyQuality: 1))
        XCTAssertEqual(automatic.decision.mode, .automatic)
        XCTAssertEqual(legacy.decision.mode, .legacy)
        XCTAssertLessThan(automatic.data.count, legacy.data.count)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(automatic.data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, width)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, height)
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, 1)
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:10:14 12:34:56")
        let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        XCTAssertEqual(maker?["17"] as? String, "12345678-1234-1234-1234-123456789ABC")
        if automatic.decision.codec == .heif10 {
            XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 10)
        }

        let decoded = try XCTUnwrap(CIImage(data: automatic.data))
        var actual = [Float](repeating: 0, count: pixels.count)
        context.render(decoded, toBitmap: &actual, rowBytes: width * 16,
            bounds: image.extent, format: .RGBAf, colorSpace: colorSpace)
        var squaredError = 0.0
        for index in pixels.indices where index % 4 != 3 {
            let error = Double(pixels[index] - actual[index])
            squaredError += error * error
        }
        let psnr = -10 * log10(squaredError / Double(width * height * 3))
        XCTAssertGreaterThan(psnr, 35, "Automatic compression must preserve the gradient and fine texture")
    }

    func testCancelledEncoderDoesNotProduceAFallbackImage() {
        let cancellation = CaptureRenderCancellation()
        cancellation.cancel()
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
        XCTAssertNil(PhotoImageEncoder.encode(image, context: Self.makeContext(),
            colorSpace: FilmImagePipeline.colorSpace, cancellation: cancellation))
    }

    private static func makeContext() -> CIContext {
        let options: [CIContextOption: Any] = [.workingColorSpace: FilmImagePipeline.colorSpace,
            .outputColorSpace: FilmImagePipeline.colorSpace, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }
}
