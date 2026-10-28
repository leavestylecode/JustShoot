import XCTest
import CoreImage
import CryptoKit
@testable import JustShoot

final class BundledFilmLUTTests: XCTestCase {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let modelSourceCommit: String
        let modelLicenseFile: String
        let stocks: [Stock]
    }

    private struct Stock: Decodable {
        let resourceName: String
        let status: String
        let dimension: Int
        let sha256: String
        let referenceSamples: [ReferenceSample]?
    }

    private struct ReferenceSample: Decodable {
        let input: [Float]
        let output: [Float]
    }

    private func resource(_ name: String, extension suffix: String) throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: suffix))
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resource("LUTProvenance", extension: "json")))
    }

    private func original(_ name: String) throws -> CubeLUT {
        try CubeLUT.parse(FilmProcessor.readCubeText(from: resource(name, extension: "cube")))
    }

    func testProvenanceCoversEveryStockAndShipsTheModelLicense() throws {
        let provenance = try manifest()
        XCTAssertEqual(provenance.schemaVersion, 2)
        XCTAssertEqual(provenance.modelSourceCommit, "bcbcfc6861f49cc706dc5d00ea048e4853060aab")
        let filmStocks = FilmPreset.allCases.filter { $0.rawSimulation == nil }
        // Preserve the earlier community Provia source and its audit trail,
        // while the existing preset ID now selects official RAW PROVIA.
        let archivedSources: Set<String> = ["FujiProvia100F"]
        XCTAssertEqual(Set(provenance.stocks.map(\.resourceName)),
                       Set(filmStocks.map(\.lutResourceName)).union(archivedSources))
        XCTAssertEqual(provenance.stocks.count, filmStocks.count + archivedSources.count)
        XCTAssertTrue(provenance.stocks.allSatisfy { $0.status == "communityModel" })
        let license = try String(contentsOf: resource("SpectralFilmLUT-LICENSE", extension: "txt"), encoding: .utf8)
        XCTAssertEqual(provenance.modelLicenseFile, "SpectralFilmLUT-LICENSE.txt")
        XCTAssertTrue(license.contains("Copyright (c) 2026 Jan Lohse"))
        XCTAssertTrue(license.contains("Permission is hereby granted"))
        for stock in provenance.stocks {
            let data = try Data(contentsOf: resource(stock.resourceName, extension: "cube"))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, stock.sha256, stock.resourceName)
        }
    }

    func testBundledSourcesLoadWithoutTheSupersededToeAndPortraitCurves() throws {
        let processor = FilmProcessor()
        for stock in try manifest().stocks {
            let raw = try original(stock.resourceName)
            let loaded = try processor.loadCubeLUT(resourceName: stock.resourceName)
            XCTAssertEqual(raw.dimension, stock.dimension)
            XCTAssertEqual(loaded.dimension, stock.dimension)
            XCTAssertEqual(loaded.data, raw.data, stock.resourceName)
            let inGamut = loaded.data.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 4).allSatisfy { offset in
                    let value = bytes.loadUnaligned(fromByteOffset: offset, as: Float.self)
                    return value.isFinite && (0...1).contains(value)
                }
            }
            XCTAssertTrue(inGamut, stock.resourceName)
        }
    }

    func testCoreImageMatchesSourceReferenceColorsInSRGB() throws {
        let space = FilmImagePipeline.colorSpace
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        for stock in try manifest().stocks {
            let samples = try XCTUnwrap(stock.referenceSamples)
            let inputs: [Float] = samples.flatMap { sample -> [Float] in sample.input + [1] }
            let image = CIImage(bitmapData: inputs.withUnsafeBufferPointer { Data(buffer: $0) },
                bytesPerRow: inputs.count * 4, size: CGSize(width: samples.count, height: 1),
                format: .RGBAf, colorSpace: space)
            let loaded = try FilmProcessor().loadCubeLUT(resourceName: stock.resourceName)
            let stages = try XCTUnwrap(FilmImagePipeline.stages(for: image, lut: loaded,
                chromaticGain: .one, optics: .disabled, grain: .disabled, grainSeed: 1))
            var output = [Float](repeating: 0, count: inputs.count)
            context.render(stages.graded, toBitmap: &output, rowBytes: output.count * 4,
                bounds: image.extent, format: .RGBAf, colorSpace: space)
            for (index, sample) in samples.enumerated() {
                for channel in 0..<3 {
                    XCTAssertEqual(output[index * 4 + channel], sample.output[channel], accuracy: 0.002,
                        "\(stock.resourceName) input=\(sample.input) channel=\(channel)")
                }
                XCTAssertEqual(output[index * 4 + 3], 1, accuracy: 0.0001)
            }
        }
    }

    func testImportWithABuiltInFilenameKeepsOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["KodakPortra400", "FujiC200"] {
            let url = root.appendingPathComponent(name).appendingPathExtension("cube")
            try FileManager.default.copyItem(at: resource(name, extension: "cube"), to: url)
            let imported = try FilmProcessor().loadCubeLUTFromFile(url: url, cacheKey: "imported-\(name)")
            XCTAssertEqual(imported.data, try original(name).data)
        }
    }
}
