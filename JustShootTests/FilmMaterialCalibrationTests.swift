import XCTest
import CoreImage
@testable import JustShoot

@MainActor
final class FilmMaterialCalibrationTests: XCTestCase {
    private let space = FilmImagePipeline.colorSpace

    private func image(_ colors: [SIMD3<Float>], width: Int, height: Int = 1) -> CIImage {
        let values: [Float] = (0..<(width * height)).flatMap { i in
            let c = colors[(i % width) % colors.count]
            return [c.x, c.y, c.z, 1]
        }
        return CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
    }

    private func render(_ input: CIImage, material: FilmMaterial, grain: FilmGrainParameters = .disabled,
        seed: UInt32 = 123) throws -> [Float] {
        var lut = FilmMaterial.identity().cube
        lut.material = material
        let output = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: lut, chromaticGain: .one,
            optics: .disabled, grain: grain, grainSeed: seed)).final
        let width = Int(input.extent.width), height = Int(input.extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        CIContext(options: [.workingColorSpace: space, .outputColorSpace: space, .workingFormat: CIFormat.RGBAf])
            .render(output, toBitmap: &pixels, rowBytes: width * 16, bounds: output.extent, format: .RGBAf, colorSpace: space)
        return pixels
    }

    private func luma(_ pixels: [Float]) -> [Float] {
        stride(from: 0, to: pixels.count, by: 4).map {
            pixels[$0] * 0.2126 + pixels[$0 + 1] * 0.7152 + pixels[$0 + 2] * 0.0722
        }
    }

    private func statistics(_ values: [Float]) -> (mean: Double, deviation: Double) {
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        return (mean, sqrt(values.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(values.count)))
    }

    func testCalibrationIsFrozenOptionalAndRejectedOnLegacyDensityModel() throws {
        let current = try FilmMaterial.loadSpectralPortra()
        let decoded = try FilmMaterial.decode(current.encoded())
        XCTAssertEqual(decoded.calibration, .portra)
        XCTAssertEqual(try current.encoded(), try decoded.encoded())
        let old = try FilmMaterial.loadSpectralPortraV1()
        XCTAssertNil(try FilmMaterial.decode(old.encoded()).calibration)
        XCTAssertNil(try FilmMaterial.loadSpectralPortra(balanced: false).calibration)
        var legacy = try XCTUnwrap(FilmMaterial.loadLegacy(preset: .kodakPortra400))
        legacy.calibration = .portra
        XCTAssertThrowsError(try legacy.encoded())
        for bad in [FilmMaterialCalibration(shadowLift: .nan, toneCeiling: 0.6, grainScale: 0.65),
                    .init(shadowLift: 1.01, toneCeiling: 0.6, grainScale: 0.65),
                    .init(shadowLift: 0.65, toneCeiling: 0, grainScale: 0.65),
                    .init(shadowLift: 0.65, toneCeiling: 0.6, grainScale: -0.01)] {
            var material = current
            material.calibration = bad
            XCTAssertThrowsError(try material.encoded())
        }
    }

    func testToneLiftsShadowsWithoutPlateausOrHighlightChanges() throws {
        let gray = (0...4096).map { SIMD3<Float>(repeating: Float($0) / 4096) }
        let input = image(gray, width: gray.count)
        let old = try render(input, material: FilmMaterial.loadSpectralPortraV1())
        let new = try render(input, material: FilmMaterial.loadSpectralPortra())
        let a = luma(old), b = luma(new)
        XCTAssertTrue(new.allSatisfy { $0.isFinite && (-0.000001...1.000001).contains($0) })
        var lifted = 0, unchanged = 0
        for i in gray.indices {
            if a[i] >= 0.6 {
                for c in 0..<3 { XCTAssertEqual(new[i * 4 + c], old[i * 4 + c], accuracy: 0.000002) }
                unchanged += 1
            }
            if (0.03...0.25).contains(a[i]) && gray[i].x >= 0.12 {
                XCTAssertGreaterThan(b[i], a[i] + 0.012)
                lifted += 1
            }
            if i > 0 { XCTAssertGreaterThan(b[i] - b[i - 1], 0, "gray=\(i)") }
        }
        for c in 0..<3 { XCTAssertEqual(new[c], old[c], accuracy: 0.000002, "Preserve printed black") }
        XCTAssertGreaterThan(lifted, 100)
        XCTAssertGreaterThan(unchanged, 100)
    }

    func testDenseColorVolumeKeepsGamutAndChromaDirection() throws {
        var colors: [SIMD3<Float>] = []
        for b in 0...16 { for g in 0...16 { for r in 0...16 {
            colors.append(SIMD3(Float(r), Float(g), Float(b)) / 16)
        } } }
        let input = image(colors, width: colors.count)
        let old = try render(input, material: FilmMaterial.loadSpectralPortraV1())
        let new = try render(input, material: FilmMaterial.loadSpectralPortra())
        for i in colors.indices {
            let a = SIMD3(old[i * 4], old[i * 4 + 1], old[i * 4 + 2])
            let b = SIMD3(new[i * 4], new[i * 4 + 1], new[i * 4 + 2])
            for c in 0..<3 {
                XCTAssertTrue(b[c].isFinite && (-0.000002...1.000002).contains(b[c]))
                XCTAssertGreaterThanOrEqual(b[c], a[c] - 0.000002)
                if a[c] < 0.999 && a[c] > 0.001 { XCTAssertLessThan(b[c], 0.99999) }
            }
            // A luma change may reduce saturation, but must not rotate the RGB opponent direction.
            let u = SIMD2(a.x - a.y, a.z - a.y), v = SIMD2(b.x - b.y, b.z - b.y)
            XCTAssertEqual(u.x * v.y - u.y * v.x, 0, accuracy: 0.000002)
        }
    }

    func testGrainCalibrationReducesVarianceWithoutMovingMeanAcrossSeedsAndScales() throws {
        let current = try FilmMaterial.loadSpectralPortra()
        var stronger = current
        stronger.calibration = .init(shadowLift: 0.65, toneCeiling: 0.60, grainScale: 1)
        let grain = FilmSource.preset(.kodakPortra400).captureRenderProfile.grain
        var measurements: [[String: Double]] = []
        for width in [256, 1536] {
            for level: Float in [0.12, 0.35, 0.6] {
                let input = image([SIMD3(repeating: level)], width: width, height: 32)
                let quiet = statistics(luma(try render(input, material: current)))
                for seed: UInt32 in [123, 9876] {
                    let a = statistics(luma(try render(input, material: stronger, grain: grain, seed: seed)))
                    let b = statistics(luma(try render(input, material: current, grain: grain, seed: seed)))
                    measurements.append(["width": Double(width), "inputGray": Double(level), "seed": Double(seed),
                        "unscaledMean": a.mean, "calibratedMean": b.mean, "quietMean": quiet.mean,
                        "unscaledDeviation": a.deviation, "calibratedDeviation": b.deviation])
                    XCTAssertLessThan(abs(b.mean - quiet.mean), 0.003)
                    XCTAssertLessThan(abs(b.mean - a.mean), 0.003)
                    XCTAssertGreaterThan(b.deviation / a.deviation, 0.5)
                    XCTAssertLessThan(b.deviation / a.deviation, 0.8)
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["JUSTSHOOT_GRAIN_REVIEW"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: url.appendingPathComponent("statistics.json"), options: .atomic)
        }
    }

    func testOptionalGrainCandidatesOnPortraitsAndNightScene() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtures = environment["JUSTSHOOT_SCENE_FIXTURES"],
              let destination = environment["JUSTSHOOT_GRAIN_REVIEW"] else {
            throw XCTSkip("Provide SDR fixtures and a grain review directory for the candidate sweep")
        }
        let url = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let profile = FilmSource.preset(.kodakPortra400).captureRenderProfile
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space, .workingFormat: CIFormat.RGBAf])
        for name in ["portrait-daylight", "portrait-window", "neon"] {
            let input = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: fixtures).appendingPathComponent(name + ".png")))
            for scale: Float in [0.45, 0.65, 0.8, 1] {
                var material = try FilmMaterial.loadSpectralPortra()
                material.calibration = .init(shadowLift: 0.65, toneCeiling: 0.60, grainScale: scale)
                var lut = FilmMaterial.identity().cube
                lut.material = material
                let output = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: lut, chromaticGain: .one,
                    optics: profile.optics, grain: profile.grain, grainSeed: 123)).final
                let png = try XCTUnwrap(context.pngRepresentation(of: output, format: .RGBA8, colorSpace: space))
                try png.write(to: url.appendingPathComponent("\(name)-grain-\(Int((scale * 100).rounded())).png"), options: .atomic)
            }
        }
    }
}
