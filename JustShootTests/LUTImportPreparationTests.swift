import XCTest
@testable import JustShoot

final class LUTImportPreparationTests: XCTestCase {
    private func cube(scale: Float = 1) throws -> CubeLUT {
        try CubeLUT.parse("LUT_3D_SIZE 2\n" + (0...1).flatMap { b in
            (0...1).flatMap { g in (0...1).map { r in "\(Float(r) * scale) \(Float(g) * scale) \(Float(b) * scale)" } }
        }.joined(separator: "\n"))
    }

    func testSRGBImportPreservesEverySourceSampleAndCompiledBytesRoundTrip() throws {
        let source = try cube(scale: 0.73)
        let canonical = try LUTImportPreparation.canonicalCube(source, encoding: .sRGB)
        XCTAssertEqual(canonical.data, source.data)
        let decoded = try FilmProcessor.decodeCompiledLUT(LUTImportPreparation.compiledData(canonical))
        XCTAssertEqual(decoded.data, source.data)
        XCTAssertEqual(decoded.dimension, source.dimension)
    }

    func testRec709Gamma24ConvertsBothSidesRatherThanOnlyChangingTheTag() throws {
        let converted = try LUTImportPreparation.canonicalCube(cube(scale: 0.65), encoding: .rec709Gamma24)
        XCTAssertEqual(converted.dimension, 65)
        for index in [1, 8, 24, 32, 48, 64] {
            let s = Float(index) / 64
            let linear = s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            // A 0.65 multiplier in gamma 2.4 equals this linear gain.
            let result = linear * pow(Float(0.65), 2.4)
            let expected = result <= 0.0031308 ? result * 12.92 : 1.055 * pow(result, 1 / 2.4) - 0.055
            let actual = converted.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 16, as: Float.self) }
            XCTAssertEqual(actual, expected, accuracy: 0.00001)
        }
        let identity = try LUTImportPreparation.canonicalCube(cube(), encoding: .rec709Gamma24)
        for index in 0...64 {
            let value = identity.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 16, as: Float.self) }
            XCTAssertEqual(value, Float(index) / 64, accuracy: 0.00001)
        }
    }

    func testNewCompiledAndExistingTextImportsReloadThroughTheSameLoader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("normalized.jslut")
        let source = try cube(scale: 0.8)
        let dimension = try await LUTImportPreparation.shared.save(source, encoding: .sRGB, to: destination)
        XCTAssertEqual(dimension, 2)
        let processor = FilmProcessor()
        XCTAssertEqual(try processor.loadCubeLUTFromFile(url: destination, cacheKey: "compiled").data, source.data)
        processor.removeCachedLUT(cacheKey: "compiled")
        XCTAssertEqual(try processor.loadCubeLUTFromFile(url: destination, cacheKey: "compiled").data, source.data)
        let legacy = directory.appendingPathComponent("legacy.cube")
        try "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(try processor.loadCubeLUTFromFile(url: legacy, cacheKey: "legacy").data, try cube().data)
    }

    func testCancellationDoesNotCreateAnIndexedOrPartialFile() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).jslut")
        defer { try? FileManager.default.removeItem(at: destination) }
        let source = try cube()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LUTImportPreparation.shared.save(source, encoding: .rec709Gamma24, to: destination)
        }
        do { _ = try await task.value; XCTFail("Cancelled import must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLogShapersAndNonUnitDomainsFailExplicitly() {
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 2\n0 0 0\n1 1 1"))
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\nDOMAIN_MAX 2 2 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1"))
    }
}
