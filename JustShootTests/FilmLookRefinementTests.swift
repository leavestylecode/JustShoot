import XCTest
@testable import JustShoot

final class FilmLookRefinementTests: XCTestCase {
    private func sample(_ cube: CubeLUT, _ input: SIMD3<Float>) -> SIMD3<Float> {
        cube.data.withUnsafeBytes { storage in
            let table = storage.bindMemory(to: Float.self)
            let point = input * Float(cube.dimension - 1)
            let lower = SIMD3(Int(floor(point.x)), Int(floor(point.y)), Int(floor(point.z)))
            let f = point - SIMD3(Float(lower.x), Float(lower.y), Float(lower.z))
            var result = SIMD3<Float>.zero
            for b in 0...1 { for g in 0...1 { for r in 0...1 {
                let x = min(lower.x + r, cube.dimension - 1)
                let y = min(lower.y + g, cube.dimension - 1)
                let z = min(lower.z + b, cube.dimension - 1)
                let weight = (r == 0 ? 1 - f.x : f.x) * (g == 0 ? 1 - f.y : f.y) * (b == 0 ? 1 - f.z : f.z)
                let offset = ((z * cube.dimension + y) * cube.dimension + x) * 4
                result += SIMD3(table[offset], table[offset + 1], table[offset + 2]) * weight
            } } }
            return result
        }
    }

    private func luma(_ rgb: SIMD3<Float>) -> Float {
        rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
    }

    private func hue(_ rgb: SIMD3<Float>) -> Float {
        let y = luma(rgb)
        return atan2((rgb.x - y) / 1.5748, (rgb.z - y) / 1.8556)
    }

    func testEveryPreparedLookMatchesIndependentPythonReference() throws {
        let processor = FilmProcessor()
        for item in FilmLookRefinementReference.samples {
            let cube = try processor.loadLUT(source: .preset(item.film))
            let actual = sample(cube, item.input)
            for channel in 0..<3 {
                XCTAssertEqual(actual[channel], item.output[channel], accuracy: 0.000002,
                    "\(item.film) input=\(item.input) channel=\(channel)")
            }
        }
    }

    func testRefinementKeepsBlackWhiteAndDaylightSignatureColors() throws {
        let processor = FilmProcessor()
        let probes: [SIMD3<Float>] = [.zero, .one, SIMD3(0.3, 0.6, 0.95),
            SIMD3(0.15, 0.45, 0.18), SIMD3(repeating: 0.75)]
        for film in FilmPreset.allCases {
            let original = try processor.loadCubeLUT(resourceName: film.lutResourceName)
            let refined = try processor.loadLUT(source: .preset(film))
            XCTAssertEqual(refined.dimension, original.dimension)
            for input in probes {
                let before = sample(original, input), after = sample(refined, input)
                for channel in 0..<3 { XCTAssertEqual(after[channel], before[channel], accuracy: 0.000002) }
            }
            let inGamut = refined.data.withUnsafeBytes { storage in
                storage.bindMemory(to: Float.self).allSatisfy { $0.isFinite && (0...1).contains($0) }
            }
            XCTAssertTrue(inGamut, "\(film)")
        }
    }

    func testColoredLooksReduceBrightSkinHueDisplacementAndRetainMostOfTheirStyle() throws {
        let processor = FilmProcessor()
        let skin: [SIMD3<Float>] = [SIMD3(0.78, 0.59, 0.48), SIMD3(0.55, 0.39, 0.30)]
        for film in FilmPreset.allCases where film != .fujiRawACROS {
            let original = try processor.loadCubeLUT(resourceName: film.lutResourceName)
            let refined = try processor.loadLUT(source: .preset(film))
            for input in skin {
                let before = sample(original, input), after = sample(refined, input)
                let oldError = abs(hue(before) - hue(input)), newError = abs(hue(after) - hue(input))
                XCTAssertLessThan(newError, oldError * 0.90, "\(film)")
                XCTAssertGreaterThan(newError, oldError * 0.30, "Keep characteristic warmth/coolness")
                XCTAssertLessThan(abs(luma(after) - luma(before)), 0.045, "Do not flatten portrait tone")
            }
        }
    }

    func testHardToeLooksRestoreInputShadowSeparationWithoutLiftingPureBlack() throws {
        let processor = FilmProcessor()
        for film in [FilmPreset.fujiRawVelvia, .fujiRawClassicChrome, .fujiRawACROS, .fujiProvia100F] {
            let original = try processor.loadCubeLUT(resourceName: film.lutResourceName)
            let refined = try processor.loadLUT(source: .preset(film))
            let low = SIMD3<Float>(repeating: 0.04), high = SIMD3<Float>(repeating: 0.10)
            let before = luma(sample(original, high)) - luma(sample(original, low))
            let after = luma(sample(refined, high)) - luma(sample(refined, low))
            XCTAssertGreaterThan(after, before + 0.003, "\(film)")
            XCTAssertEqual(sample(original, .zero), sample(refined, .zero))
            // The rescue retains a dark rendering rather than forcing input brightness.
            XCTAssertLessThan(luma(sample(refined, high)), 0.06)
        }
    }

    func testACROSRemainsMonochrome() throws {
        let cube = try FilmProcessor().loadLUT(source: .preset(.fujiRawACROS))
        cube.data.withUnsafeBytes { storage in
            let values = storage.bindMemory(to: Float.self)
            for index in stride(from: 0, to: values.count, by: 4) {
                XCTAssertEqual(values[index], values[index + 1], accuracy: 0.000002)
                XCTAssertEqual(values[index], values[index + 2], accuracy: 0.000002)
            }
        }
    }

    func testEvictedRefinementAndCurveRebuildWhileLegacyResourceKeysStayOriginal() throws {
        let processor = FilmProcessor(maximumLUTCacheBytes: 0)
        let source = FilmSource.preset(.fujiC200)
        let original = try processor.loadCubeLUT(resourceName: FilmPreset.fujiC200.lutResourceName)
        let captured = try processor.loadLUT(source: source)
        XCTAssertNotEqual(captured.data, original.data)
        XCTAssertNil(processor.cachedLUT(cacheKey: source.lutCacheKey))
        XCTAssertEqual(try XCTUnwrap(processor.resolveLUT(cacheKey: source.lutCacheKey)).data, captured.data)
        XCTAssertEqual(try XCTUnwrap(processor.resolveLUT(cacheKey: FilmPreset.fujiC200.lutResourceName)).data, original.data)
        let curve = FilmCurve.builtIn(.filmSoft)
        let key = processor.composedLUTCacheKey(source.lutCacheKey, curve: curve)
        XCTAssertEqual(try XCTUnwrap(processor.resolveLUT(cacheKey: key)).data,
            try processor.loadLUT(source: source, curve: curve).data)
        XCTAssertEqual(processor.cachedLUTBytes, 0)
    }

    func testCustomImportDoesNotReceiveBuiltInSkinOrShadowRefinement() throws {
        let name = "refinement-test-\(UUID().uuidString).jslut"
        let directory = CustomLUT.storageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "KodakPortra400", withExtension: "jslut"))
        try FileManager.default.copyItem(at: bundled, to: url)
        let source = FilmSource.custom(id: UUID(), displayName: "Portra", iso: 400, fileName: name)
        let imported = try FilmProcessor().loadLUT(source: source)
        let original = try FilmProcessor.decodeCompiledLUT(Data(contentsOf: bundled))
        XCTAssertEqual(imported.data, original.data)
        XCTAssertFalse(source.lutCacheKey.contains(FilmLookRefinement.revision))
    }
}
