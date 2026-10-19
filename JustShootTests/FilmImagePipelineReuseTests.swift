import XCTest
import CoreImage
import CoreVideo
@testable import JustShoot

final class FilmImagePipelineReuseTests: XCTestCase {
    private let space = FilmImagePipeline.colorSpace
    private lazy var context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
    private let bounds = CGRect(x: 0, y: 0, width: 16, height: 8)

    func testDeferredOutputGraphsKeepTheirOwnFrameAfterFilterReuse() throws {
        let lut = cube()
        let filter = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: lut))
        let inputs = [image(red: 0.8, green: 0.2, blue: 0.1), image(red: 0.1, green: 0.7, blue: 0.3),
                      image(red: 0.2, green: 0.1, blue: 0.9)]
        // Render only after every mutable input has changed, as a lazy CI graph permits.
        let outputs = try inputs.map { try XCTUnwrap(filter.applying(to: $0)) }
        for (input, output) in zip(inputs, outputs) {
            assertPixels(pixels(output), pixels(input))
        }
        XCTAssertNotEqual(pixels(outputs[0]), pixels(outputs[1]))
    }

    func testSeparateTranscodesKeepTheirOwnCube() throws {
        let identity = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: cube()))
        let inverted = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: cube(inverted: true)))
        let input = image(red: 0.8, green: 0.2, blue: 0.1)
        let first = try XCTUnwrap(identity.applying(to: input))
        let second = try XCTUnwrap(inverted.applying(to: input))
        _ = identity.applying(to: image(red: 0.1, green: 0.2, blue: 0.8))
        assertPixels(pixels(first), pixels(input))
        assertPixels(pixels(second), pixels(image(red: 0.2, green: 0.8, blue: 0.9)))
    }

    func testReusedLiveFilterMatchesFreshGraphAcrossFramesWithAllEffects() throws {
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 8,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool), kCVReturnSuccess)
        let actualPool = try XCTUnwrap(pool)
        let lut = try FilmProcessor().loadCubeLUT(resourceName: FilmPreset.kodakPortra400.lutResourceName)
        let filter = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: lut))
        let profile = FilmPreset.kodakPortra400.renderProfile
        for frame in 0..<4 {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, actualPool, &buffer), kCVReturnSuccess)
            let source = try XCTUnwrap(buffer)
            let input = image(red: CGFloat(frame) * 0.2 + 0.1, green: 0.4, blue: 0.8)
            context.render(input, to: source, bounds: bounds, colorSpace: space)
            FilmVideoColorSpace.tag(source)
            let seed = FilmGrainRenderer.temporalSeed(base: 42, seconds: Double(frame) / 30)
            let gain = profile.effectiveChromatic.responseGain(sceneCCT: 3_200)
            let reused = try XCTUnwrap(LivePhotoProcessor.renderFrame(source, lut: lut, lutFilter: filter,
                grain: profile.grain, optics: profile.optics, chromaticGain: gain,
                protectChromaticHighlights: true, grainSeed: seed, pool: actualPool))
            let fresh = try XCTUnwrap(LivePhotoProcessor.renderFrame(source, lut: lut,
                grain: profile.grain, optics: profile.optics, chromaticGain: gain,
                protectChromaticHighlights: true, grainSeed: seed, pool: actualPool))
            assertPixels(pixels(CIImage(cvPixelBuffer: reused)), pixels(CIImage(cvPixelBuffer: fresh)))
        }
    }

    private func image(red: CGFloat, green: CGFloat, blue: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue)).cropped(to: bounds)
    }

    private func pixels(_ image: CIImage) -> [Float] {
        var values = [Float](repeating: 0, count: 16 * 8 * 4)
        values.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16 * 4 * MemoryLayout<Float>.size,
                bounds: bounds, format: .RGBAf, colorSpace: space)
        }
        return values
    }

    private func assertPixels(_ actual: [Float], _ expected: [Float], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs, rhs, accuracy: 0.003, file: file, line: line)
        }
    }

    private func cube(inverted: Bool = false) -> CubeLUT {
        var values: [Float] = []
        for blue in 0...1 {
            for green in 0...1 {
                for red in 0...1 {
                    values.append(Float(inverted ? 1 - red : red))
                    values.append(Float(inverted ? 1 - green : green))
                    values.append(Float(inverted ? 1 - blue : blue))
                    values.append(1)
                }
            }
        }
        return CubeLUT(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: 2)
    }
}
