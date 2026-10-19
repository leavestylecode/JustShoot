import XCTest
import CoreImage
@testable import JustShoot

final class FilmLUTCalibrationTests: XCTestCase {
    private func original(_ preset: FilmPreset) throws -> CubeLUT {
        let url = try XCTUnwrap(Bundle.main.url(forResource: preset.lutResourceName, withExtension: "cube"))
        return try CubeLUT.parse(FilmProcessor.readCubeText(from: url))
    }

    private func rgba(_ lut: CubeLUT) -> [Float] {
        lut.data.withUnsafeBytes { bytes in
            (0..<(bytes.count / 4)).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }

    private func grayResponse(_ lut: CubeLUT) throws -> [Float] {
        let space = FilmImagePipeline.colorSpace
        let values = (0...1024).flatMap { value -> [Float] in
            let gray = Float(value) / 1024
            return [gray, gray, gray, 1]
        }
        let image = CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: values.count * 4, size: CGSize(width: 1025, height: 1), format: .RGBAf, colorSpace: space)
        let stages = try XCTUnwrap(FilmImagePipeline.stages(for: image, lut: lut, chromaticGain: .one,
            optics: .disabled, grain: .disabled, grainSeed: 1))
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        var output = [Float](repeating: 0, count: values.count)
        context.render(stages.graded, toBitmap: &output, rowBytes: output.count * 4,
            bounds: image.extent, format: .RGBAf, colorSpace: space)
        return (0...1024).map { output[$0 * 4] * 0.2126 + output[$0 * 4 + 1] * 0.7152 + output[$0 * 4 + 2] * 0.0722 }
    }

    func testPortraitStocksReducePeakMidtoneContrastWithoutFlatteningWhite() throws {
        for preset in [FilmPreset.kodakPortra400, .fujiPro400H] {
            let before = try grayResponse(original(preset))
            let after = try grayResponse(FilmProcessor().loadCubeLUT(resourceName: preset.lutResourceName))
            func peak(_ ramp: [Float]) -> Float {
                (256..<768).map { (ramp[$0 + 1] - ramp[$0]) * 1024 }.max() ?? 0
            }
            let originalPeak = peak(before), calibratedPeak = peak(after)
            print("portrait_tone_check stock=\(preset.lutResourceName) original_peak=\(originalPeak) calibrated_peak=\(calibratedPeak)")
            XCTAssertLessThan(calibratedPeak, originalPeak * 0.94)
            XCTAssertGreaterThan(calibratedPeak, 1, "Keep tonal separation instead of flattening the image")
            XCTAssertLessThan(abs(after[512] - before[512]), 0.04)
            XCTAssertLessThan(abs(after[1024] - before[1024]), 0.02)
            XCTAssertGreaterThan(after[184], before[184], "Lift the dense lower midtones gently")
            for index in 850..<1024 {
                XCTAssertGreaterThan(after[index + 1] - after[index], -0.001,
                    "Do not introduce significant highlight reversals")
            }
        }
    }

    func testCalibrationPreservesHueDirectionAndKeepsEveryNodeInGamut() throws {
        for preset in [FilmPreset.kodakPortra400, .fujiPro400H] {
            let base = try original(preset)
            let source = rgba(CurveLUTComposer.preparedSource(base))
            let calibrated = FilmLUTCalibration.applying(to: base, resourceName: preset.lutResourceName)
            let output = rgba(calibrated)
            XCTAssertEqual(calibrated.dimension, 33)
            XCTAssertEqual(output.count, source.count)
            for offset in stride(from: 0, to: output.count, by: 4) {
                let old = SIMD3(source[offset], source[offset + 1], source[offset + 2])
                let new = SIMD3(output[offset], output[offset + 1], output[offset + 2])
                // RGB differences remove the neutral-axis offset. A common scale
                // preserves their direction, including the warm skin-tone region.
                let a = SIMD3(old.x - old.y, old.y - old.z, old.z - old.x)
                let b = SIMD3(new.x - new.y, new.y - new.z, new.z - new.x)
                let cross = SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
                XCTAssertLessThan(max(abs(cross.x), abs(cross.y), abs(cross.z)), 0.000001)
                for channel in [new.x, new.y, new.z] {
                    XCTAssertTrue(channel.isFinite)
                    XCTAssertGreaterThanOrEqual(channel, -0.000001)
                    XCTAssertLessThanOrEqual(channel, 1.000001)
                }
                XCTAssertEqual(output[offset + 3], source[offset + 3])
            }
        }
    }

    func test400HShadowRefinementKeepsBlackAndBrightTonesWithSmoothSeparation() throws {
        let identity = try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1")
        let calibrated = FilmLUTCalibration.applying(to: identity, resourceName: FilmPreset.fujiPro400H.lutResourceName)
        let refined = try grayResponse(calibrated)
        let nodes = rgba(calibrated)
        // The first-batch 400H response is the reference, before the localized
        // dark-gray refinement. Fixed black/midtone/highlight anchors must survive.
        let reference = CurveMath.expand(CurveMath.points([
            (0, 0), (0.12, 0.140), (0.30, 0.315), (0.60, 0.585), (0.82, 0.810), (1, 1)
        ]))
        func previous(_ index: Int) -> Float { CurveMath.sample(reference, at: Float(index) / 1024) }
        func neutralNode(_ node: Int) -> Float {
            let offset = ((node * 33 + node) * 33 + node) * 4
            return nodes[offset]
        }
        for node in [0, 1, 16, 24, 32] {
            // Inspect frozen float LUT anchors directly; Core Image can choose
            // a quantized optimization for this one-dimensional gray fixture.
            XCTAssertEqual(neutralNode(node), previous(node * 32), accuracy: 0.000001)
        }
        let beforeSeparation = previous(256) - previous(128)
        let afterSeparation = neutralNode(8) - neutralNode(4)
        XCTAssertLessThan(afterSeparation, beforeSeparation * 0.97)
        XCTAssertGreaterThan(afterSeparation, beforeSeparation * 0.90)
        for index in refined.indices {
            XCTAssertLessThan(abs(refined[index] - previous(index)), 0.008)
            if index > 0 { XCTAssertGreaterThanOrEqual(refined[index] - refined[index - 1], -0.00001) }
        }
    }

    func testOtherStocksAndImportedLUTBytesRemainUnchanged() throws {
        for preset in FilmPreset.allCases where preset != .kodakPortra400 && preset != .fujiPro400H {
            let base = try original(preset)
            XCTAssertEqual(FilmLUTCalibration.applying(to: base, resourceName: preset.lutResourceName).data, base.data)
        }
        // Even a file with the same name as a built-in stock is an imported recipe.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("KodakPortra400.cube")
        let text = try FilmProcessor.readCubeText(from: XCTUnwrap(Bundle.main.url(
            forResource: FilmPreset.kodakPortra400.lutResourceName, withExtension: "cube")))
        try text.write(to: url, atomically: true, encoding: .utf8)
        let imported = try FilmProcessor().loadCubeLUTFromFile(url: url, cacheKey: "imported-portra")
        XCTAssertEqual(imported.data, try CubeLUT.parse(text).data)
    }
}
