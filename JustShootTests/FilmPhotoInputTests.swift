import CoreImage
import ImageIO
import XCTest
@testable import JustShoot

final class FilmPhotoInputTests: XCTestCase {
    func testHDRPhotoIsToneMappedBeforeDisplayLUTSampling() async throws {
        let work = BlockingImageWork(maximumConcurrentOperations: 1, label: "com.justshoot.test-hdr-input")
        let result = await work.run { () -> Result<Void, any Error>? in
            Result {
                let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
                let pq = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
                let levels: [Float] = [0.1, 1, 4, 8]
                let values = (0..<(64 * 16)).flatMap { pixel -> [Float] in
                    let level = levels[(pixel % 64) / 16]
                    return [level, level, level, 1]
                }
                let input = CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) },
                    bytesPerRow: 64 * 16, size: CGSize(width: 64, height: 16), format: .RGBAf, colorSpace: linear)
                let context = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
                let data = try context.heif10Representation(of: input, colorSpace: pq)
                let hdr = try XCTUnwrap(CIImage(data: data, options: [.toneMapHDRtoSDR: false]))
                let sdr = try XCTUnwrap(FilmImagePipeline.decodePhoto(data))
                let displayContext = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace,
                    .cacheIntermediates: false])
                func samples(_ image: CIImage) -> [Float] {
                    var pixels = [Float](repeating: 0, count: 64 * 16 * 4)
                    displayContext.render(image, toBitmap: &pixels, rowBytes: 64 * 16,
                        bounds: CGRect(x: 0, y: 0, width: 64, height: 16), format: .RGBAf, colorSpace: linear)
                    return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
                }
                let mapped = samples(sdr)
                XCTAssertGreaterThan(samples(hdr).max() ?? 0, 2, "The fixture must actually contain HDR values")
                XCTAssertLessThanOrEqual(mapped.max() ?? 0, 1.001, "A display LUT must receive SDR")
                XCTAssertLessThan(mapped[20], mapped[36] - 0.03, "Tone mapping must retain highlight steps instead of clipping both to white")
                XCTAssertEqual(sdr.extent, input.extent)
            }
        }
        try XCTUnwrap(result).get()
    }

    func testSDRPhotoKeepsItsPixelsAndOptionalOrientation() async throws {
        let work = BlockingImageWork(maximumConcurrentOperations: 1, label: "com.justshoot.test-sdr-input")
        let result = await work.run { () -> Result<Void, any Error>? in
            Result {
                let context = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace])
                let input = CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2))
                    .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
                    .settingProperties([kCGImagePropertyOrientation as String: 6])
                let data = try XCTUnwrap(context.jpegRepresentation(of: input,
                    colorSpace: FilmImagePipeline.colorSpace))
                let original = try XCTUnwrap(CIImage(data: data))
                let decoded = try XCTUnwrap(FilmImagePipeline.decodePhoto(data))
                let oriented = try XCTUnwrap(FilmImagePipeline.decodePhoto(data, applyOrientation: true))
                XCTAssertEqual(decoded.extent, original.extent)
                XCTAssertEqual(oriented.extent.size, CGSize(width: 48, height: 64))
                func sample(_ image: CIImage) -> [UInt8] {
                    var value = [UInt8](repeating: 0, count: 4)
                    context.render(image, toBitmap: &value, rowBytes: 4,
                        bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                        colorSpace: FilmImagePipeline.colorSpace)
                    return value
                }
                XCTAssertEqual(sample(decoded), sample(original), "An SDR input must not be tone mapped a second time")
            }
        }
        try XCTUnwrap(result).get()
    }
}
