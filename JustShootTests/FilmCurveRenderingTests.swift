import XCTest
@testable import JustShoot

final class FilmCurveRenderingTests: XCTestCase {
    private func filmFixture(red: Float, green: Float, blue: Float) throws -> (FilmProcessor, String, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("film.cube")
        let row = "\(red) \(green) \(blue)"
        let text = "LUT_3D_SIZE 2\n" + Array(repeating: row, count: 8).joined(separator: "\n")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let processor = FilmProcessor(maximumLUTCacheBytes: 4_096)
        let key = "film-\(UUID().uuidString)"
        _ = try processor.loadCubeLUTFromFile(url: file, cacheKey: key)
        return (processor, key, directory)
    }

    private func linearPoints(black: Float, white: Float) -> [CurveControlPoint] {
        [CurveControlPoint(input: 0, output: black), CurveControlPoint(input: 1, output: white)]
    }

    private func firstRGBA(_ lut: CubeLUT) -> [Float] {
        lut.data.withUnsafeBytes { bytes in
            (0..<4).map { bytes.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.stride, as: Float.self) }
        }
    }

    func testCurveCompositionRunsAfterTheFilmResponse() throws {
        let (processor, filmKey, directory) = try filmFixture(red: 0.2, green: 0.4, blue: 0.6)
        defer { try? FileManager.default.removeItem(at: directory) }
        var definition = CustomFilmCurve(name: "Print curve")
        definition.masterPoints = linearPoints(black: 0.1, white: 0.9)
        let curve = FilmCurve.custom(definition)
        let key = processor.composedLUTCacheKey(filmKey, curve: curve)
        let output = firstRGBA(try XCTUnwrap(processor.resolveLUT(cacheKey: key)))
        // The film returns constants regardless of its input. Applying the curve before
        // that film would leave 0.2/0.4/0.6 unchanged; the real composition must transform them.
        XCTAssertEqual(output[0], 0.26, accuracy: 0.00001)
        XCTAssertEqual(output[1], 0.42, accuracy: 0.00001)
        XCTAssertEqual(output[2], 0.58, accuracy: 0.00001)
        XCTAssertEqual(output[3], 1)
    }

    func testRGBChannelCurvesKeepTheirOwnChannelAndFollowTheMasterCurve() throws {
        let (processor, filmKey, directory) = try filmFixture(red: 0.2, green: 0.4, blue: 0.6)
        defer { try? FileManager.default.removeItem(at: directory) }
        var definition = CustomFilmCurve(name: "RGB curve")
        definition.masterPoints = linearPoints(black: 0.1, white: 0.9)
        definition.redPoints = linearPoints(black: 0.1, white: 0.9)
        definition.greenPoints = linearPoints(black: 1, white: 0)
        definition.bluePoints = linearPoints(black: 0, white: 0.5)
        let curve = FilmCurve.custom(definition)
        let key = processor.composedLUTCacheKey(filmKey, curve: curve)
        let output = firstRGBA(try XCTUnwrap(processor.resolveLUT(cacheKey: key)))
        XCTAssertEqual(output[0], 0.308, accuracy: 0.00001) // red(master(0.2))
        XCTAssertEqual(output[1], 0.58, accuracy: 0.00001)  // green(master(0.4))
        XCTAssertEqual(output[2], 0.29, accuracy: 0.00001)  // blue(master(0.6))
        XCTAssertEqual(output[3], 1)
    }

    func testIdentityCustomCurveKeepsFiniteHDRValuesAndOriginalBytes() throws {
        let (processor, filmKey, directory) = try filmFixture(red: -0.2, green: 0.5, blue: 1.25)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try XCTUnwrap(processor.resolveLUT(cacheKey: filmKey))
        let identity = FilmCurve.custom(CustomFilmCurve(name: "Identity"))
        XCTAssertTrue(identity.isNeutral)
        let key = processor.composedLUTCacheKey(filmKey, curve: identity)
        let composed = try XCTUnwrap(processor.resolveLUT(cacheKey: key))
        XCTAssertEqual(key, filmKey)
        XCTAssertEqual(composed.data, original.data)
        XCTAssertEqual(firstRGBA(composed), [-0.2, 0.5, 1.25, 1])
    }

    func testEditingTheSelectedCurveChangesItsKeyWithoutMutatingACapturedLUT() throws {
        let (processor, filmKey, directory) = try filmFixture(red: 0.2, green: 0.4, blue: 0.6)
        defer { try? FileManager.default.removeItem(at: directory) }
        var definition = CustomFilmCurve(name: "Selected curve")
        definition.masterPoints = linearPoints(black: 0.1, white: 0.9)
        let selected = FilmCurve.custom(definition)
        let originalKey = processor.composedLUTCacheKey(filmKey, curve: selected)
        let captured = try XCTUnwrap(processor.resolveLUT(cacheKey: originalKey))
        let frozenBytes = captured.data
        definition.masterPoints = linearPoints(black: 0.2, white: 0.8)
        let edited = FilmCurve.custom(definition)
        let editedKey = processor.composedLUTCacheKey(filmKey, curve: edited)
        let updated = try XCTUnwrap(processor.resolveLUT(cacheKey: editedKey))
        XCTAssertEqual(edited.id, selected.id)
        XCTAssertNotEqual(editedKey, originalKey)
        XCTAssertNotEqual(updated.data, frozenBytes)
        XCTAssertEqual(captured.data, frozenBytes)
        XCTAssertEqual(try XCTUnwrap(processor.resolveLUT(cacheKey: originalKey)).data, frozenBytes)
    }
}
