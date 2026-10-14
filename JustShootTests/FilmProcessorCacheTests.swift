import XCTest
@testable import JustShoot

final class FilmProcessorCacheTests: XCTestCase {
    private var identityText: String {
        "LUT_3D_SIZE 2\n" + (0...1).flatMap { blue in
            (0...1).flatMap { green in (0...1).map { red in "\(red) \(green) \(blue)" } }
        }.joined(separator: "\n")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCube(in root: URL, named name: String, text: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension("cube")
        try (text ?? identityText).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEvictedFileLUTReloadsFromItsActualRegisteredURL() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = FilmProcessor(maximumLUTCacheBytes: 256)
        let firstURL = try writeCube(in: root, named: "first")
        let original = try processor.loadCubeLUTFromFile(url: firstURL, cacheKey: "first")
        _ = try processor.loadCubeLUTFromFile(url: writeCube(in: root, named: "second"), cacheKey: "second")
        _ = try processor.loadCubeLUTFromFile(url: writeCube(in: root, named: "third"), cacheKey: "third")
        XCTAssertNil(processor.cachedLUT(cacheKey: "first"))

        // The filename deliberately does not match a UUID-derived cache key.
        let updated = identityText.replacingOccurrences(of: "1 1 1", with: "0.8 0.9 1")
        try updated.write(to: firstURL, atomically: true, encoding: .utf8)
        let reloaded = try XCTUnwrap(processor.resolveLUT(cacheKey: "first"))
        XCTAssertNotEqual(reloaded.data, original.data)
        XCTAssertEqual(reloaded.data, try CubeLUT.parse(updated).data)
        XCTAssertLessThanOrEqual(processor.cachedLUTBytes, 256)
        XCTAssertEqual(original.data, try CubeLUT.parse(identityText).data)
    }

    func testEvictedCompositionRebuildsItsBaseWithoutChangingCaptureSnapshot() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let composedBytes = 33 * 33 * 33 * 16
        let processor = FilmProcessor(maximumLUTCacheBytes: composedBytes)
        _ = try processor.loadCubeLUTFromFile(url: writeCube(in: root, named: "film"), cacheKey: "film")
        let key = processor.composedLUTCacheKey("film", curve: .builtIn(.matte))
        let snapshot = try XCTUnwrap(processor.resolveLUT(cacheKey: key))
        _ = try processor.loadCubeLUTFromFile(url: writeCube(in: root, named: "other"), cacheKey: "other")
        XCTAssertNil(processor.cachedLUT(cacheKey: key))
        let rebuilt = try XCTUnwrap(processor.resolveLUT(cacheKey: key))
        XCTAssertEqual(rebuilt.data, snapshot.data)
        XCTAssertEqual(processor.cachedLUTBytes, composedBytes)
        XCTAssertEqual(processor.cachedLUTCount, 1)
    }

    func testSourcePreparationWorksWhenNoTableFitsTheCacheBudget() throws {
        let processor = FilmProcessor(maximumLUTCacheBytes: 0)
        let source = FilmSource.preset(.fujiC200)
        let curve = FilmCurve.builtIn(.filmSoft)
        let captured = try processor.loadLUT(source: source, curve: curve)
        let rebuilt = try processor.loadLUT(source: source, curve: curve)
        XCTAssertEqual(rebuilt.data, captured.data)
        XCTAssertEqual(captured.data.count, captured.dimension * captured.dimension * captured.dimension * 16)
        XCTAssertEqual(processor.cachedLUTCount, 0)
        XCTAssertEqual(processor.cachedLUTBytes, 0)
    }

    func testCurrentPreparationRestoresAnEvictedCurveRecipe() throws {
        let processor = FilmProcessor(maximumLUTCacheBytes: 0, maximumRecipeEntries: 2)
        let source = FilmSource.preset(.fujiC200)
        let captured = try processor.loadLUT(source: source, curve: .builtIn(.filmSoft))
        let key = processor.composedLUTCacheKey(source.lutCacheKey, curve: .builtIn(.filmSoft))
        _ = processor.composedLUTCacheKey(source.lutCacheKey, curve: .builtIn(.matte))
        _ = processor.composedLUTCacheKey(source.lutCacheKey, curve: .builtIn(.punch))
        XCTAssertNil(processor.resolveLUT(cacheKey: key))
        let prepared = try processor.loadLUT(source: source, curve: .builtIn(.filmSoft))
        XCTAssertEqual(prepared.data, captured.data)
        XCTAssertEqual(try XCTUnwrap(processor.resolveLUT(cacheKey: key)).data, captured.data)
    }

    func testDeletingCustomLUTRemovesItsSourceAndDependentCompositions() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let processor = FilmProcessor(maximumLUTCacheBytes: 1_024)
        _ = try processor.loadCubeLUTFromFile(url: writeCube(in: root, named: "film"), cacheKey: "film")
        let key = processor.composedLUTCacheKey("film", curve: .builtIn(.matte))
        XCTAssertNotNil(processor.resolveLUT(cacheKey: key))
        processor.removeCachedLUT(cacheKey: "film")
        XCTAssertNil(processor.resolveLUT(cacheKey: "film"))
        XCTAssertNil(processor.resolveLUT(cacheKey: key))
        XCTAssertEqual(processor.cachedLUTBytes, 0)
    }
}
