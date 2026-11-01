import XCTest
import CoreImage
@testable import JustShoot

@MainActor
final class FilmColorBalanceTests: XCTestCase {
    private let space = FilmImagePipeline.colorSpace
    private lazy var context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
        .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    private func image(_ rgb: [SIMD3<Float>]) -> CIImage {
        let values: [Float] = rgb.flatMap { value -> [Float] in [value.x, value.y, value.z, 1] }
        return CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: rgb.count * 16, size: CGSize(width: rgb.count, height: 1), format: .RGBAf, colorSpace: space)
    }

    private func pixels(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &values, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
        return values
    }

    private func render(_ rgb: [SIMD3<Float>], balanced: Bool) throws -> [SIMD3<Float>] {
        try render(rgb, balance: balanced ? .portra : nil)
    }

    private func render(_ rgb: [SIMD3<Float>], balance: FilmColorBalanceParameters?) throws -> [SIMD3<Float>] {
        var lut = FilmMaterial.identity().cube
        var material = try XCTUnwrap(FilmMaterial.loadLegacy(preset: .kodakPortra400, balanced: false))
        material.colorBalance = balance
        lut.material = material
        let stages = try XCTUnwrap(FilmImagePipeline.stages(for: image(rgb), lut: lut, chromaticGain: .one,
            optics: .disabled, grain: .disabled, grainSeed: 123))
        let values = pixels(stages.final)
        return stride(from: 0, to: values.count, by: 4).map { SIMD3(values[$0], values[$0 + 1], values[$0 + 2]) }
    }

    private func luma(_ rgb: SIMD3<Float>) -> Float { rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722 }
    private func uv(_ rgb: SIMD3<Float>) -> SIMD2<Float> {
        let y = luma(rgb)
        return SIMD2((rgb.z - y) / 1.8556, (rgb.x - y) / 1.5748)
    }
    private func length(_ value: SIMD2<Float>) -> Float { sqrt(value.x * value.x + value.y * value.y) }
    private func hue(_ rgb: SIMD3<Float>) -> Float { let c = uv(rgb); return atan2(c.y, c.x) }

    func testNeutralShadowsLoseMostIntroducedCastWithoutChangingExposureOrGraySeparation() throws {
        let input = (0...100).map { SIMD3<Float>(repeating: Float($0) / 100) }
        let before = try render(input, balanced: false), after = try render(input, balanced: true)
        for i in input.indices {
            XCTAssertEqual(luma(after[i]), luma(before[i]), accuracy: 0.000002)
            if (5...50).contains(i) {
                XCTAssertLessThan(length(uv(after[i])), length(uv(before[i])) * 0.40)
            }
            if i > 0 {
                XCTAssertEqual(luma(after[i]) - luma(after[i - 1]),
                    luma(before[i]) - luma(before[i - 1]), accuracy: 0.000003)
            }
        }
    }

    func testSkinHueMovesPartwayTowardInputAndChromaDoesNotIncrease() throws {
        let input: [SIMD3<Float>] = [SIMD3(0.78, 0.59, 0.48), SIMD3(0.55, 0.39, 0.30),
            SIMD3(0.30, 0.19, 0.12), SIMD3(0.14, 0.09, 0.06)]
        let before = try render(input, balanced: false), after = try render(input, balanced: true)
        for i in input.indices {
            let oldError = abs(hue(before[i]) - hue(input[i])), newError = abs(hue(after[i]) - hue(input[i]))
            XCTAssertLessThan(newError, oldError * 0.9, "Reduce the additional orange shift")
            XCTAssertGreaterThan(newError, oldError * 0.2, "Retain the film's color preference")
            XCTAssertLessThanOrEqual(length(uv(after[i])), length(uv(before[i])) + 0.000002)
            XCTAssertEqual(luma(after[i]), luma(before[i]), accuracy: 0.000002)
        }
    }

    func testMutedRedSkinImprovesBeyondV1WithoutLosingItsHueOrBrightness() throws {
        // Red/pink deep-skin colors from the daylight input missed v1's yellow-orange gate.
        let input: [SIMD3<Float>] = [SIMD3(0.41, 0.31, 0.31), SIMD3(0.30, 0.21, 0.20),
            SIMD3(0.65, 0.48, 0.43), SIMD3(0.78, 0.59, 0.48)]
        let previous = try render(input, balance: .portraV1), current = try render(input, balance: .portra)
        for i in input.indices {
            XCTAssertLessThan(abs(hue(current[i]) - hue(input[i])), abs(hue(previous[i]) - hue(input[i])) * 0.90)
            XCTAssertLessThanOrEqual(length(uv(current[i])), length(uv(previous[i])) + 0.000002)
            XCTAssertEqual(luma(current[i]), luma(previous[i]), accuracy: 0.000002)
        }
    }

    func testPortraitHighlightRampKeepsExistingLumaDetailAndWarmLightEndpoint() throws {
        let skin = SIMD3<Float>(0.78, 0.59, 0.48)
        let input = (0...256).map { skin + (SIMD3<Float>.one - skin) * Float($0) / 256 }
        let previous = try render(input, balance: .portraV1), current = try render(input, balance: .portra)
        for i in input.indices {
            XCTAssertEqual(luma(current[i]), luma(previous[i]), accuracy: 0.000002)
            if i > 0 {
                XCTAssertEqual(luma(current[i]) - luma(current[i - 1]),
                    luma(previous[i]) - luma(previous[i - 1]), accuracy: 0.000003)
            }
            if luma(input[i]) >= 0.90 {
                for channel in 0..<3 { XCTAssertEqual(current[i][channel], previous[i][channel], accuracy: 0.000002) }
            }
        }
    }

    func testBlackWhiteBrightWarmLightAndSaturatedSignatureColorsStayUnchanged() throws {
        let input: [SIMD3<Float>] = [.zero, .one, SIMD3(repeating: 0.92), SIMD3(1, 0.9, 0.75),
            SIMD3(0.3, 0.6, 0.95), SIMD3(0.15, 0.45, 0.18), SIMD3(0.95, 0.04, 0.09), SIMD3(0.1, 0.9, 0.9)]
        let before = try render(input, balanced: false), after = try render(input, balanced: true)
        for i in input.indices { for channel in 0..<3 {
            XCTAssertEqual(after[i][channel], before[i][channel], accuracy: 0.000002)
        } }
    }

    func testColorVolumeStaysFiniteInGamutAndPreservesLuma() throws {
        var input: [SIMD3<Float>] = []
        for b in 0...16 { for g in 0...16 { for r in 0...16 {
            input.append(SIMD3(Float(r), Float(g), Float(b)) / 16)
        } } }
        let before = try render(input, balanced: false), after = try render(input, balanced: true)
        for i in input.indices {
            XCTAssertEqual(luma(after[i]), luma(before[i]), accuracy: 0.000002)
            for channel in 0..<3 { XCTAssertTrue(after[i][channel].isFinite && (0...1).contains(after[i][channel])) }
        }
    }

    func testFrozenLegacyMaterialDoesNotAcquireNewColorBalanceAndNewRecipeRoundTrips() throws {
        let current = try XCTUnwrap(FilmMaterial.loadLegacy(preset: .kodakPortra400))
        XCTAssertEqual(current.colorBalance, .portra)
        let restored = try FilmMaterial.decode(current.encoded())
        XCTAssertEqual(restored.colorBalance, current.colorBalance)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: current.encoded(), format: nil) as? [String: Any])
        plist.removeValue(forKey: "colorBalance")
        let oldBytes = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let legacy = try FilmMaterial.decode(oldBytes)
        XCTAssertNil(legacy.colorBalance)
        let processor = FilmProcessor(maximumLUTCacheBytes: 0)
        let oldKey = FilmPreset.kodakPortra400.lutResourceName + FilmLookRefinement.cacheSuffix + FilmMaterial.revision
        XCTAssertNil(try XCTUnwrap(processor.resolveLUT(cacheKey: oldKey)?.material).colorBalance)
        let firstKey = oldKey + FilmColorBalanceParameters.legacyCacheSuffix
        let first = try XCTUnwrap(processor.resolveLUT(cacheKey: firstKey)?.material)
        XCTAssertEqual(first.colorBalance, .portraV1)
        let firstRestored = try FilmMaterial.decode(first.encoded())
        XCTAssertEqual(firstRestored.colorBalance, .portraV1)
        XCTAssertNil(firstRestored.colorBalance?.skinResponse)
        XCTAssertEqual(try XCTUnwrap(processor.resolveLUT(cacheKey: FilmSource.preset(.kodakPortra400).lutCacheKey)?.material).colorBalance, .portra)
        XCTAssertEqual(FilmSource.preset(.fujiC200).lutCacheKey, FilmPreset.fujiC200.lutResourceName + FilmLookRefinement.cacheSuffix)
        var invalid = current
        invalid.colorBalance = .init(neutralRetention: .nan, skinHueRetention: 0.3, skinChromaRetention: 0.3)
        XCTAssertThrowsError(try invalid.encoded())
    }

    func testOptionalPhotographsExportBeforeAfterAndKeepStillLiveIdentical() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtures = environment["JUSTSHOOT_SCENE_FIXTURES"],
              let directory = environment["JUSTSHOOT_COLOR_BALANCE_EXPORT"] else {
            throw XCTSkip("Provide SDR fixtures and an export directory for the photographic review")
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: fixtures), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.path < $1.path }
        XCTAssertFalse(urls.isEmpty)
        let profile = FilmSource.preset(.kodakPortra400).captureRenderProfile
        let variants: [(String, FilmColorBalanceParameters?)] = [("before", nil), ("v1", .portraV1), ("after", .portra)]
        for (variant, balance) in variants {
            var lut = try FilmProcessor.shared.loadLUT(source: .preset(.kodakPortra400))
            var material = try XCTUnwrap(FilmMaterial.loadLegacy(preset: .kodakPortra400, balanced: false))
            material.colorBalance = balance
            lut.material = material
            let filter = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: lut))
            for url in urls {
                try autoreleasepool {
                    let input = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
                    let stages = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: lut, chromaticGain: .one,
                        optics: profile.optics, grain: profile.grain, grainSeed: 123))
                    let live = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: nil, lutFilter: filter, chromaticGain: .one,
                        optics: profile.optics, grain: profile.grain, grainSeed: 123))
                    let values = pixels(stages.final)
                    XCTAssertEqual(values, pixels(live.final), url.lastPathComponent)
                    XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1.0001).contains($0) })
                    for (mode, image) in [("color", stages.graded), ("full", stages.final)] {
                        let name = url.deletingPathExtension().lastPathComponent + "-" + variant + "-" + mode
                        let png = try XCTUnwrap(context.pngRepresentation(of: image, format: .RGBA8, colorSpace: space))
                        try png.write(to: out.appendingPathComponent(name + ".png"), options: .atomic)
                    }
                    print("color_balance_export variant=\(variant) scene=\(url.lastPathComponent)")
                }
            }
        }
    }
}
