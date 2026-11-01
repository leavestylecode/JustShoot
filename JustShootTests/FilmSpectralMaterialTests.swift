import XCTest
import CoreImage
@testable import JustShoot

@MainActor
final class FilmSpectralMaterialTests: XCTestCase {
    private let space = FilmImagePipeline.colorSpace

    private func lut(_ material: FilmMaterial) -> CubeLUT {
        var lut = FilmMaterial.identity().cube
        lut.material = material
        return lut
    }

    private func render(_ image: CIImage, linearWorkingSpace: Bool = false) -> [Float] {
        let context = CIContext(options: [.workingColorSpace: linearWorkingSpace ? RawFilmRenderer.linearSpace : space,
            .outputColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &values, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
        return values
    }

    func testFrozenDomainsAreExplicitAndSchemaOneRemainsIndependent() throws {
        let spectral = try FilmMaterial.loadSpectralPortra(balanced: false)
        XCTAssertEqual(spectral.version, 2)
        XCTAssertEqual(spectral.contract, .spectralSDR)
        XCTAssertEqual(spectral.densityFloor, SIMD3(repeating: -0.2))
        XCTAssertNotEqual(spectral.identifier, try FilmMaterial.loadLegacy(preset: .kodakPortra400)?.identifier)
        XCTAssertEqual(spectral.byteCount, 8_788_256)
        let restored = try FilmMaterial.decode(spectral.encoded())
        XCTAssertEqual(restored.densityFloor, spectral.densityFloor)
        XCTAssertEqual(restored.contract, spectral.contract)
        XCTAssertEqual(try restored.encoded(), try spectral.encoded())
        let old = try XCTUnwrap(FilmMaterial.loadLegacy(preset: .kodakPortra400))
        let decoded = try FilmMaterial.decode(old.encoded())
        XCTAssertNil(decoded.contract)
        XCTAssertNil(decoded.densityMinimum)
        XCTAssertEqual(decoded.densityFloor, .zero)
        var incomplete = spectral
        incomplete.contract = nil
        XCTAssertThrowsError(try incomplete.encoded())
        incomplete = spectral
        incomplete.densityMinimum = nil
        XCTAssertThrowsError(try incomplete.encoded())
        incomplete = spectral
        incomplete.densityMinimum = SIMD3(.nan, -0.2, -0.2)
        XCTAssertThrowsError(try incomplete.encoded())
        incomplete = old
        incomplete.contract = .spectralSDR
        XCTAssertThrowsError(try incomplete.encoded())
    }

    func testNativeColorMatchesFullUpstreamReferenceAndWorkingSpaces() throws {
        struct Manifest: Decodable {
            struct Reference: Decodable { let input: [Float]; let output: [Float] }
            let references: [Reference]
        }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "SpekPortraEndura-material-v1", withExtension: "json"))
        let refs = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).references
        let values: [Float] = refs.flatMap { $0.input + [Float(1)] }
        let input = CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: refs.count * 16,
            size: CGSize(width: refs.count, height: 1), format: .RGBAf, colorSpace: space)
        let material = try FilmMaterial.loadSpectralPortra(balanced: false)
        let output = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: lut(material),
            chromaticGain: .one, optics: .disabled, grain: .disabled, grainSeed: 1)).final
        let actual = render(output), linear = render(output, linearWorkingSpace: true)
        for i in refs.indices { for c in 0..<3 {
            XCTAssertEqual(actual[i * 4 + c], refs[i].output[c], accuracy: 0.004, "probe=\(i) channel=\(c)")
            XCTAssertEqual(actual[i * 4 + c], linear[i * 4 + c], accuracy: 0.002)
        } }
    }

    func testDefaultUsesSpectralCoreAndEveryOldCacheKeyRetainsItsModel() throws {
        let processor = FilmProcessor(maximumLUTCacheBytes: 0)
        let current = try processor.loadLUT(source: .preset(.kodakPortra400))
        XCTAssertEqual(current.dimension, 2, "Do not retain an unused legacy RGB cube")
        XCTAssertEqual(current.material?.identifier, "spek-portra-endura-density-v1")
        XCTAssertEqual(current.material?.colorBalance, .portra)
        XCTAssertEqual(current.material?.calibration, .portra)
        XCTAssertEqual(try FilmMaterial.load(preset: .kodakPortra400)?.identifier, current.material?.identifier)
        XCTAssertNil(try FilmMaterial.load(preset: .fujiC200))
        let key = FilmSource.preset(.kodakPortra400).lutCacheKey
        XCTAssertTrue(key.contains(FilmMaterial.spectralRevision))
        XCTAssertEqual(processor.resolveLUT(cacheKey: key)?.material?.identifier, current.material?.identifier)
        let old = FilmPreset.kodakPortra400.lutResourceName + FilmLookRefinement.cacheSuffix + FilmMaterial.revision
        for (suffix, balance) in [("", nil), (FilmColorBalanceParameters.legacyCacheSuffix, FilmColorBalanceParameters.portraV1),
                                  (FilmColorBalanceParameters.cacheSuffix, FilmColorBalanceParameters.portra)] {
            let frozen = try XCTUnwrap(processor.resolveLUT(cacheKey: old + suffix)?.material)
            XCTAssertEqual(frozen.version, 1)
            XCTAssertEqual(frozen.identifier, "portra-endura-density-v1")
            XCTAssertEqual(frozen.colorBalance, balance)
        }
        XCTAssertNil(processor.resolveLUT(cacheKey: old + "#unrecognized-model"))
        let firstSpectralKey = FilmPreset.kodakPortra400.lutResourceName + FilmLookRefinement.cacheSuffix
            + FilmMaterial.spectralV1Revision + FilmColorBalanceParameters.cacheSuffix
        let frozenSpectral = try XCTUnwrap(processor.resolveLUT(cacheKey: firstSpectralKey)?.material)
        XCTAssertEqual(frozenSpectral.identifier, current.material?.identifier)
        XCTAssertNil(frozenSpectral.calibration)
        XCTAssertEqual(try frozenSpectral.encoded(), try FilmMaterial.loadSpectralPortraV1().encoded())
    }

    func testHighlightRampRetainsSeparationThroughSelectedOutputShoulder() throws {
        let width = 1025
        let values: [Float] = (0..<width).flatMap { i in
            let gray = Float(i) / Float(width - 1)
            return [gray, gray, gray, 1]
        }
        let input = CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: 1), format: .RGBAf, colorSpace: space)
        let current = try FilmProcessor().loadLUT(source: .preset(.kodakPortra400))
        let selected = FilmSource.preset(.kodakPortra400).captureRenderProfile.optics
        let stages = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: current, chromaticGain: .one,
            optics: selected, grain: .disabled, grainSeed: 1))
        // The graded branch isolates the pointwise model. The final branch also
        // includes the selected diffusion/shoulder, whose response must stay ordered.
        for output in [stages.graded, stages.final] {
            let pixels = render(output)
            let luma = (0..<width).map { i in
                pixels[i * 4] * 0.2126 + pixels[i * 4 + 1] * 0.7152 + pixels[i * 4 + 2] * 0.0722
            }
            XCTAssertTrue(luma.allSatisfy { $0.isFinite && (0...1).contains($0) })
            for i in 768..<(width - 1) {
                XCTAssertGreaterThan(luma[i + 1] - luma[i], 0.000001, "No new highlight plateau at \(i)")
            }
        }
    }

    func testOptionalPhotographsExportCoreAndBalancedWithStillLiveParity() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtures = environment["JUSTSHOOT_SCENE_FIXTURES"],
              let directory = environment["JUSTSHOOT_SPECTRAL_EXPORT"] else {
            throw XCTSkip("Provide SDR fixtures and a destination for the native photographic comparison")
        }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        let profile = FilmSource.preset(.kodakPortra400).captureRenderProfile
        let variants: [(String, FilmMaterial)] = [
            ("previous", try XCTUnwrap(FilmMaterial.loadLegacy(preset: .kodakPortra400))),
            ("core", try FilmMaterial.loadSpectralPortra(balanced: false)),
            ("balanced", try FilmMaterial.loadSpectralPortraV1()),
            ("calibrated", try FilmMaterial.loadSpectralPortra())]
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: fixtures), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.path < $1.path }
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            let input = try XCTUnwrap(CIImage(contentsOf: url))
            for (name, material) in variants {
                let lut = lut(material)
                let filter = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: lut))
                for full in [false, true] {
                    let optics: FilmOpticsParameters = full ? profile.optics : .disabled
                    let grain: FilmGrainParameters = full ? profile.grain : .disabled
                    let still = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: lut, chromaticGain: .one,
                        optics: optics, grain: grain, grainSeed: 123)).final
                    let live = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: nil, lutFilter: filter, chromaticGain: .one,
                        optics: optics, grain: grain, grainSeed: 123)).final
                    XCTAssertEqual(render(still), render(live), "scene=\(url.lastPathComponent) model=\(name)")
                    let data = try XCTUnwrap(context.pngRepresentation(of: still, format: .RGBA8, colorSpace: space))
                    try data.write(to: destination.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(name)-\(full ? "full" : "color").png"), options: .atomic)
                }
            }
        }
    }
}
