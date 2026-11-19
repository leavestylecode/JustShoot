import XCTest
import CoreImage
import CryptoKit
@testable import JustShoot

final class BundledFilmLUTTests: XCTestCase {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let modelSourceCommit: String
        let modelLicense: String
        let stocks: [Stock]
    }

    private struct Stock: Decodable {
        let resourceName: String
        let status: String
        let dimension: Int
        let sha256: String
        let referenceSamples: [ReferenceSample]?
    }

    private struct HaldManifest: Decodable {
        let license: String
        let stocks: [Stock]
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

    private func haldManifest() throws -> HaldManifest {
        try JSONDecoder().decode(HaldManifest.self,
            from: Data(contentsOf: resource("RawTherapeeLUTProvenance", extension: "json")))
    }

    private func stocks() throws -> [Stock] {
        try manifest().stocks + haldManifest().stocks
    }

    private func original(_ name: String) throws -> CubeLUT {
        try CubeLUT.parse(FilmProcessor.readCubeText(from: resource(name, extension: "cube")))
    }

    func testBundledLUTsCreditTheProjectAdaptation() throws {
        struct Adaptation: Decodable {
            let adaptedBy: String
        }

        for name in ["LUTProvenance", "RawTherapeeLUTProvenance", "RawLUTProvenance", "PortraEndura-material-v1"] {
            let data = try Data(contentsOf: resource(name, extension: "json"))
            let adaptation = try JSONDecoder().decode(Adaptation.self, from: data)
            XCTAssertEqual(adaptation.adaptedBy, "Leavestylecode", name)
        }

        for stock in try stocks() {
            let url = try resource(stock.resourceName, extension: "cube")
            let cube = try String(contentsOf: url, encoding: .utf8)
            let headerEnd = try XCTUnwrap(cube.range(of: "LUT_3D_SIZE")?.lowerBound)
            let comments = cube[..<headerEnd].split(whereSeparator: \.isNewline).filter { $0.hasPrefix("#") }
            XCTAssertEqual(comments, ["# Adapted by Leavestylecode"], stock.resourceName)
        }
    }

    func testProvenanceCoversEveryStockAndMatchesSourceHashes() throws {
        let provenance = try manifest()
        XCTAssertEqual(provenance.schemaVersion, 2)
        XCTAssertEqual(provenance.modelSourceCommit, "bcbcfc6861f49cc706dc5d00ea048e4853060aab")
        let filmStocks = FilmPreset.allCases.filter { $0.rawSimulation == nil }
        let allStocks = try stocks()
        XCTAssertEqual(Set(allStocks.map(\.resourceName)), Set(filmStocks.map(\.lutResourceName)))
        XCTAssertEqual(allStocks.count, filmStocks.count)
        XCTAssertTrue(provenance.stocks.allSatisfy { $0.status == "communityModel" })
        XCTAssertEqual(provenance.modelLicense, "MIT")
        let hald = try haldManifest()
        XCTAssertEqual(hald.license, "CC-BY-SA-4.0")
        XCTAssertTrue(hald.stocks.allSatisfy { $0.status == "communityHaldCLUT" })
        for stock in allStocks {
            let data = try Data(contentsOf: resource(stock.resourceName, extension: "cube"))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, stock.sha256, stock.resourceName)
        }
    }

    func testBundledSourcesLoadWithoutTheSupersededToeAndPortraitCurves() throws {
        let processor = FilmProcessor()
        for stock in try stocks() {
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
        for stock in try stocks() {
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

    func testEveryMonochromePresetRetainsEqualRGBChannels() throws {
        let processor = FilmProcessor()
        for preset in FilmPreset.allCases where preset.isMonochrome {
            let cube = try processor.loadLUT(source: .preset(preset))
            cube.data.withUnsafeBytes { storage in
                let values = storage.bindMemory(to: Float.self)
                for index in stride(from: 0, to: values.count, by: 4) {
                    XCTAssertEqual(values[index], values[index + 1], accuracy: 0.000002, preset.rawValue)
                    XCTAssertEqual(values[index], values[index + 2], accuracy: 0.000002, preset.rawValue)
                }
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
