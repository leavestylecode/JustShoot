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

    func testHDRGainMapRoundTripsCapturedHighlightsAndKeepsSDRBase() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("HDR gain-map encoding requires iOS 18") }
        let linear = RawFilmRenderer.linearSpace
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 64)
        let left = CGRect(x: 0, y: 0, width: 64, height: 64)
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
        let base = CIImage(color: try XCTUnwrap(CIColor(red: 0.8, green: 0.7, blue: 0.6, colorSpace: linear)))
            .cropped(to: bounds)
        let shadows = CIImage(color: try XCTUnwrap(CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: linear)))
            .cropped(to: left)
        let highlights = CIImage(color: try XCTUnwrap(CIColor(red: 4, green: 4, blue: 4, colorSpace: linear)))
            .cropped(to: bounds)
        func red(_ image: CIImage, x: CGFloat, y: CGFloat = 32) -> Float {
            var pixel = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 16,
                bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
            return pixel[0]
        }
        let scene = shadows.composited(over: highlights)
        let hdr = try XCTUnwrap(FilmHDRHighlights.applying(to: base, source: scene))
        XCTAssertEqual(red(scene, x: 96), 4, accuracy: 0.02)
        XCTAssertEqual(red(hdr, x: 96), 2, accuracy: 0.02)
        let encoded = try XCTUnwrap(PhotoImageEncoder.encode(base, context: context,
            colorSpace: FilmImagePipeline.colorSpace, mode: .quality, hdrImage: hdr))
        let sdr = try XCTUnwrap(CIImage(data: encoded.data, options: [.expandToHDR: false]))
        XCTAssertEqual(red(sdr, x: 32), 0.8, accuracy: 0.03)
        XCTAssertEqual(red(sdr, x: 96), 0.8, accuracy: 0.03)

        #if targetEnvironment(simulator)
        guard #available(iOS 26.0, *) else { throw XCTSkip("The iOS 18 simulator omits HDR gain maps") }
        // The newer simulator exposes ISO gain-map pixels but omits their expansion metadata.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        let info = try XCTUnwrap((CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
            ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)) as? [String: Any])
        let pixels = try XCTUnwrap(info[kCGImageAuxiliaryDataInfoData as String] as? Data)
        let description = try XCTUnwrap(info[kCGImageAuxiliaryDataInfoDataDescription as String] as? [String: Int])
        let width = try XCTUnwrap(description["Width"])
        let row = try XCTUnwrap(description["BytesPerRow"]) * (try XCTUnwrap(description["Height"]) / 2)
        XCTAssertGreaterThan(pixels[row + width * 3 / 4], pixels[row + width / 4])
        #else
        let expanded = try XCTUnwrap(CIImage(data: encoded.data, options: [.expandToHDR: true]))
        XCTAssertGreaterThan(expanded.contentHeadroom, 1)
        XCTAssertEqual(red(expanded, x: 32), 0.8, accuracy: 0.08)
        XCTAssertGreaterThan(red(expanded, x: 96), 1.5)

        let rotated = base.oriented(forExifOrientation: 6)
        let grade = rotated.cropped(to: rotated.extent.insetBy(dx: 8, dy: 16))
        let rotatedHDR = try XCTUnwrap(FilmHDRHighlights.applyingNativeGainMap(from: encoded.data,
            to: grade, orientedSourceExtent: rotated.extent, exifOrientation: 6))
        XCTAssertEqual(rotatedHDR.extent, grade.extent)
        XCTAssertGreaterThan(red(rotatedHDR, x: 32, y: 32), 1.5)
        XCTAssertEqual(red(rotatedHDR, x: 32, y: 96), 0.8, accuracy: 0.08)
        #endif

        let noHighlights = try XCTUnwrap(PhotoImageEncoder.encode(base, context: context,
            colorSpace: FilmImagePipeline.colorSpace, mode: .quality, hdrImage: base))
        let neutral = try XCTUnwrap(CIImage(data: noHighlights.data, options: [.expandToHDR: true]))
        XCTAssertEqual(neutral.contentHeadroom, 1, accuracy: 0.01)
        XCTAssertNil(FilmHDRHighlights.applyingNativeGainMap(from: noHighlights.data, to: base,
            orientedSourceExtent: bounds, exifOrientation: 1))
    }

    private static func makeContext() -> CIContext {
        let options: [CIContextOption: Any] = [.workingColorSpace: FilmImagePipeline.colorSpace,
            .outputColorSpace: FilmImagePipeline.colorSpace, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }
}
