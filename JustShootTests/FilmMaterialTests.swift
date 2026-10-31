import XCTest
import CoreImage
import Metal
import AVFoundation
import ImageIO
@testable import JustShoot

@MainActor
final class FilmMaterialTests: XCTestCase {
    private let space = FilmImagePipeline.colorSpace

    private func material(refine: Bool = true) throws -> FilmMaterial {
        let m = try XCTUnwrap(FilmMaterial.load(preset: .kodakPortra400))
        return FilmMaterial(version: m.version, identifier: m.identifier, input: m.input, density: m.density,
            print: m.print, finish: m.finish, densityMaximum: m.densityMaximum,
            refinement: refine ? m.refinement : .zero)
    }
    private func image(_ values: [Float], width: Int, height: Int) -> CIImage {
        CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
    }
    private func render(_ image: CIImage, raw: Bool = false) -> [Float] {
        let context = CIContext(options: [.workingColorSpace: raw ? RawFilmRenderer.linearSpace : space,
            .outputColorSpace: space, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &values, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
        return values
    }
    private func processed(_ input: CIImage, material: FilmMaterial, grain: FilmGrainParameters = .disabled,
        optics: FilmOpticsParameters = .disabled, seed: UInt32 = 123) throws -> CIImage {
        var lut = FilmMaterial.identity().cube
        lut.material = material
        return try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: lut, chromaticGain: .one,
            optics: optics, grain: grain, grainSeed: seed)).final
    }

    func testIdentityFastPathsPreserveHighlightShoulderDiffusionAndDensityGrain() throws {
        let m = try material()
        XCTAssertTrue(m.input.isIdentity)
        XCTAssertTrue(m.finish.isIdentity)
        // A 3³ identity takes the full interpolation path, independent of the fast
        // path detector. Include values outside [0,1] to verify domain clamping.
        var nodes: [Float] = []
        for b in 0...2 { for g in 0...2 { for r in 0...2 {
            nodes += [Float(r) / 2, Float(g) / 2, Float(b) / 2, 1]
        } } }
        let table = FilmMaterial.Table(CubeLUT(data: nodes.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: 3))
        XCTAssertFalse(table.isIdentity)
        var reference = m
        reference.input = table
        reference.finish = table
        let width = 96, height = 64
        var values: [Float] = []
        for y in 0..<height { for x in 0..<width {
            values += [Float(x) / Float(width - 1) * 1.4 - 0.15,
                Float(y) / Float(height - 1) * 1.3 - 0.1, Float((x + y) % 23) / 22, 1]
        } }
        let input = image(values, width: width, height: height)
        let profile = FilmSource.preset(.kodakPortra400).captureRenderProfile
        for grain in [FilmGrainParameters.disabled, profile.grain] {
            let actual = render(try processed(input, material: m, grain: grain, optics: profile.optics))
            let expected = render(try processed(input, material: reference, grain: grain, optics: profile.optics))
            let maximum = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(maximum, 0.00005)
        }
        let decoded = try FilmMaterial.decode(m.encoded())
        XCTAssertEqual(try decoded.encoded(), try m.encoded(), "Runtime texture tokens must not change frozen recipes")
        XCTAssertNotEqual(decoded.density.textureIdentifier, m.density.textureIdentifier)
        // A non-identity 2³ cube must never be mistaken for a no-op.
        var altered = m.input.data
        altered.withUnsafeMutableBytes { $0.bindMemory(to: Float.self)[0] = 0.01 }
        XCTAssertFalse(FilmMaterial.Table(CubeLUT(data: altered, dimension: 2)).isIdentity)
    }

    func testPreviewRecipesReuseImmutableMaterialTablesAcrossWhiteBalanceAndCurves() async throws {
        let plain = try FilmProcessor().loadLUT(source: .preset(.kodakPortra400))
        let curved = FilmCurve.builtIn(.matte).applied(to: plain)
        let adjusted = try await ColorTemperatureLUT().prepare(base: curved, baseKey: "material-reuse",
            selection: .temperature(4200), tint: .value(8))
        let cache = PreviewLUTTextureCache(maximumEntries: 1)
        let first = try await cache.prepare(key: "plain", lut: plain)
        let second = try await cache.prepare(key: "adjusted", lut: adjusted)
        let a = try XCTUnwrap(first.material), b = try XCTUnwrap(second.material)
        XCTAssertTrue(a.density === b.density)
        XCTAssertTrue(a.paper === b.paper)
        XCTAssertFalse(first.texture === second.texture)
        XCTAssertFalse(a.finish === b.finish)
        XCTAssertEqual(a.identityFlags, 3)
        XCTAssertEqual(b.identityFlags, 0)
        // Eviction releases the recipe, but the active renderer can still reuse its tables.
        let revisited = try await cache.prepare(key: "plain-again", lut: plain)
        XCTAssertTrue(revisited.material?.density === a.density)
        XCTAssertTrue(revisited.material?.paper === a.paper)
        XCTAssertEqual(first.texture.width, first.dimension)
    }

    func testTwoStageColorMatchesIndependentUnbakedModelAndWorkingSpaces() throws {
        struct Manifest: Decodable {
            struct Reference: Decodable { let input: [Float]; let output: [Float] }
            let references: [Reference]
        }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PortraEndura-material-v1", withExtension: "json"))
        let refs = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).references
        let input = image(refs.flatMap { $0.input + [1] }, width: refs.count, height: 1)
        let output = try processed(input, material: material(refine: false))
        let srgb = render(output), linear = render(output, raw: true)
        for i in refs.indices { for c in 0..<3 {
            XCTAssertEqual(srgb[i * 4 + c], refs[i].output[c], accuracy: 0.012, "probe \(i) channel \(c)")
            XCTAssertEqual(srgb[i * 4 + c], linear[i * 4 + c], accuracy: 0.002)
        } }
    }

    func testDensityGrainIsDeterministicAndPassesThroughPaper() throws {
        let input = CIImage(color: CIColor(red: 0.45, green: 0.34, blue: 0.24)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        let m = try material()
        let grain = FilmGrainParameters(amount: 0.15, size: 2, chroma: 0.08, response: .balanced)
        let plain = render(try processed(input, material: m))
        let first = render(try processed(input, material: m, grain: grain))
        XCTAssertEqual(first, render(try processed(input, material: m, grain: grain)))
        XCTAssertNotEqual(first, render(try processed(input, material: m, grain: grain, seed: 124)))
        XCTAssertNotEqual(first, plain)
        XCTAssertTrue(first.allSatisfy { $0.isFinite && (0...1.0001).contains($0) })
        for c in 0..<3 {
            let mean = stride(from: c, to: first.count, by: 4).reduce(Float(0)) { $0 + first[$1] } / 16384
            XCTAssertEqual(mean, plain[c], accuracy: 0.006)
        }
    }

    func testHalationAffectsSurroundingExposureBeforeFilmAndCancellationStopsRendering() throws {
        let width = 128
        var values = [Float](repeating: 0, count: width * width * 4)
        for i in 0..<(width * width) {
            let bright = (56..<72).contains(i % width) && (56..<72).contains(i / width)
            for c in 0..<3 { values[i * 4 + c] = bright ? 1 : 0.12 }
            values[i * 4 + 3] = 1
        }
        let input = image(values, width: width, height: width), m = try material()
        let baseline = render(try processed(input, material: m))
        let optics = FilmOpticsParameters(halationAmount: 1, halationRadius: 160, halationHue: 0.2,
            bloomAmount: 0, bloomRadius: 0, headroomAmount: 0, headroomShoulder: 0)
        let halo = render(try processed(input, material: m, optics: optics))
        let neighbor = (64 * width + 52) * 4
        XCTAssertGreaterThan(abs(halo[neighbor] - baseline[neighbor]), 0.0001)
        XCTAssertEqual(halo[0], baseline[0], accuracy: 0.0001)
        var lut = FilmMaterial.identity().cube
        lut.material = m
        let cancelled = CaptureRenderCancellation()
        cancelled.cancel()
        XCTAssertNil(FilmImagePipeline.stages(for: input, lut: lut, chromaticGain: .one,
            optics: optics, grain: .disabled, grainSeed: 1, cancellation: cancelled))
    }

    func testCurvesWhiteBalanceAndTextureUploadRetainMaterialAndBudget() async throws {
        let source = FilmSource.preset(.kodakPortra400)
        let plain = try FilmProcessor.shared.loadLUT(source: source)
        let curved = try FilmProcessor.shared.loadLUT(source: source, curve: .builtIn(.matte))
        XCTAssertNotNil(curved.material)
        XCTAssertNotEqual(curved.material?.finish.data, plain.material?.finish.data)
        XCTAssertEqual(curved.material?.density.data, plain.material?.density.data)
        let adjustments = ColorTemperatureLUT()
        let adjusted = try await adjustments.prepare(base: curved, baseKey: "material-test",
            selection: .temperature(4200), tint: .automatic)
        let m = try XCTUnwrap(adjusted.material)
        XCTAssertNotEqual(m.input.data, curved.material?.input.data)
        XCTAssertEqual(m.finish.data, curved.material?.finish.data)
        XCTAssertEqual(adjusted.data, curved.data, "Material input adjustment must not rebake the unused RGB reference")
        let cachedCount = await adjustments.cachedCount
        let cachedBytes = await adjustments.cachedBytes
        XCTAssertEqual(cachedCount, 1)
        XCTAssertEqual(cachedBytes, adjusted.byteCount)
        XCTAssertLessThanOrEqual(cachedBytes, 16 * 1_024 * 1_024)
        let texture = try await PreviewLUTTextureCache.shared.prepare(key: "material-test-upload", lut: adjusted)
        XCTAssertNotNil(texture.material)
        XCTAssertGreaterThanOrEqual(texture.byteCount, m.byteCount)
        XCTAssertGreaterThan(adjusted.byteCount, adjusted.data.count)
        XCTAssertNil(try FilmProcessor.shared.loadLUT(source: .preset(.fujiC200)).material)
    }

    func testJournalFreezesMaterialAndRejectsMissingOrTamperedPayloadWithoutChangingLegacyJobs() throws {
        let lut = try FilmProcessor.shared.loadLUT(source: .preset(.kodakPortra400))
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        func recipe(_ lut: CubeLUT) -> CaptureRecipe {
            CaptureRecipe(id: UUID(), captureDate: Date(), filterName: "material-test", displayLabel: nil,
                focalLength: 28, outputQuality: nil, profile: FilmSource.preset(.kodakPortra400).captureRenderProfile,
                grainSeed: 12, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil, photoDisplayTime: nil)
        }
        let job = try journal.stage(recipe: recipe(lut), imageData: Data([1]), movieURL: nil, lut: lut)
        XCTAssertNotNil(job.recipe.materialSHA256)
        XCTAssertEqual(job.recipe.withPhotoDisplayTime(0.25).materialSHA256, job.recipe.materialSHA256)
        XCTAssertEqual(try journal.lut(for: job).material?.encoded(), try lut.material?.encoded())
        let file = journal.file("material.bin", for: job.id)
        try Data([0, 1]).write(to: file)
        XCTAssertThrowsError(try journal.lut(for: job))
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(try journal.inventory().issues.contains { $0.reason == .missingResources })
        let legacy = CubeLUT(data: lut.data, dimension: lut.dimension)
        let old = try journal.stage(recipe: recipe(legacy), imageData: Data([1]), movieURL: nil, lut: legacy)
        XCTAssertNil(old.recipe.materialSHA256)
        XCTAssertNil(try journal.lut(for: old).material)
    }

    func testUnknownMaterialVersionAndCorruptTablesAreRejected() throws {
        let m = try material()
        let unknown = FilmMaterial(version: 99, identifier: m.identifier, input: m.input, density: m.density,
            print: m.print, finish: m.finish, densityMaximum: m.densityMaximum, refinement: m.refinement)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        XCTAssertThrowsError(try unknown.encoded())
        XCTAssertThrowsError(try FilmMaterial.decode(encoder.encode(unknown)))
        var malformed = m
        var values = [Float](repeating: 1, count: 32)
        values[0] = .nan
        malformed.input = FilmMaterial.Table(CubeLUT(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, dimension: 2))
        XCTAssertThrowsError(try FilmMaterial.decode(encoder.encode(malformed)))
        malformed.input = FilmMaterial.Table(CubeLUT(data: m.input.data, dimension: 65))
        XCTAssertThrowsError(try FilmMaterial.decode(encoder.encode(malformed)))
        XCTAssertThrowsError(try FilmMaterial.decode(Data([0, 1])))
    }

    func testMaterialLiveVideoEncodesWithFrozenTablesAndStillImageTime() async throws {
        guard LivePhotoEncoderConfiguration.isSupported else { throw XCTSkip("Live Photo requires iOS 18") }
        let lut = try FilmProcessor.shared.loadLUT(source: .preset(.kodakPortra400))
        let profile = FilmSource.preset(.kodakPortra400).captureRenderProfile
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov"), output = root.appendingPathComponent("output.mov")
        try await CapturePipelineTests.makeVideo(at: source)
        _ = try await LivePhotoProcessor.process(sourceURL: source, lutCacheKey: "frozen-material-only",
            capturedLUT: lut, grain: profile.grain, optics: profile.optics, grainBaseSeed: 123,
            photoDisplayTime: CMTime(value: 3, timescale: 30), outputURL: output)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0)
        XCTAssertGreaterThan(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
    }

    func testOptionalSDRPhotographsMatchStillAndLiveWithFullMaterialEffects() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtures = environment["JUSTSHOOT_SCENE_FIXTURES"] else {
            throw XCTSkip("Provide the existing SDR scene fixtures for photographic comparisons")
        }
        let lut = try FilmProcessor.shared.loadLUT(source: .preset(.kodakPortra400))
        let legacy = CubeLUT(data: lut.data, dimension: lut.dimension)
        let filter = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: lut))
        let profile = FilmSource.preset(.kodakPortra400).captureRenderProfile
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        let export = environment["JUSTSHOOT_MATERIAL_EXPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        let fixtureURLs = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: fixtures),
            includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(fixtureURLs.isEmpty, "The fixture directory must contain SDR PNG photographs")
        for url in fixtureURLs {
            try autoreleasepool {
                let name = url.deletingPathExtension().lastPathComponent
                let input = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
                let stages = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: lut, chromaticGain: .one,
                    optics: profile.optics, grain: profile.grain, grainSeed: 123))
                let still = stages.final
                let live = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: nil, lutFilter: filter,
                    chromaticGain: .one, optics: profile.optics, grain: profile.grain, grainSeed: 123)).final
                let values = render(still)
                XCTAssertEqual(values, render(live), name)
                XCTAssertTrue(values.allSatisfy { $0.isFinite && (0...1.0001).contains($0) }, name)
                if let export {
                    let before = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: legacy, chromaticGain: .one,
                        optics: profile.optics, grain: profile.grain, grainSeed: 123))
                    for (label, image) in [("input", input), ("legacy", before.final), ("material", still),
                        ("legacy-color", before.graded), ("material-color", stages.graded),
                        ("legacy-optics", before.optical), ("material-optics", stages.optical)] {
                        let png = try XCTUnwrap(context.pngRepresentation(of: image, format: .RGBA8, colorSpace: space))
                        try png.write(to: export.appendingPathComponent(name + "-" + label + ".png"), options: .atomic)
                    }
                }
            }
        }
    }

    func testMaterialRendersDevelopedDNGWithFrozenWhiteBalanceCurveAndOrientation() async throws {
        let lut = try await ColorTemperatureLUT.shared.prepare(source: .preset(.kodakPortra400),
            curve: .builtIn(.matte), selection: .temperature(4700), tint: .value(8))
        let recipe = RawCaptureRecipe(unifiedLUT: lut)
        let data = LinearDNGFixture.make(orientation: 6)
        let profile = FilmSource.preset(.kodakPortra400).captureRenderProfile
        let output = await Task.detached(priority: .utility) {
            FilmProcessor().applyLUTPreservingMetadata(imageData: data, lutCacheKey: "frozen-material-raw",
                capturedLUT: lut, rawRecipe: recipe, grain: profile.grain, grainSeed: 123, optics: profile.optics)
        }.value
        let source = try XCTUnwrap(CGImageSourceCreateWithData(XCTUnwrap(output) as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 256)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, 1)
    }

    func testMetalPreviewMatchesStillAndLiveFilterIncludingWhiteBalanceCurveAndDensityGrain() async throws {
        let adjusted = try await ColorTemperatureLUT.shared.prepare(source: .preset(.kodakPortra400),
            curve: .builtIn(.matte), selection: .temperature(4700), tint: .value(8))
        let plain = try FilmProcessor.shared.loadLUT(source: .preset(.kodakPortra400))
        for (index, lut) in [plain, adjusted].enumerated() {
            let textures = try await PreviewLUTTextureCache.shared.prepare(key: "material-render-parity-\(index)", lut: lut)
            let material = try XCTUnwrap(textures.material)
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let library = try device.makeDefaultLibrary(bundle: .main)
            let firstPipeline = try await device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "previewLUT")))
            let finishPipeline = try await device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "previewMaterialFinish")))
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let width = 128, height = 16
            let palette: [SIMD3<Float>] = [SIMD3(0.78, 0.59, 0.48), SIMD3(0.14, 0.09, 0.06),
                SIMD3(0.3, 0.6, 0.95), SIMD3(0.15, 0.45, 0.18), SIMD3(1, 0.05, 0.12), SIMD3(repeating: 0.96)]
            let source: [Float16] = (0..<(width * height)).flatMap { i in
                let rgb = palette[i % width % palette.count]
                return [Float16(rgb.x), Float16(rgb.y), Float16(rgb.z), 1]
            }
            func texture(_ format: MTLPixelFormat) throws -> any MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
                descriptor.storageMode = .shared
                descriptor.usage = [.shaderRead, .shaderWrite]
                return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            }
            let input = try texture(.rgba16Float), exposed = try texture(.rgba16Float)
            let energy = try texture(.r16Float), output = try texture(.rgba16Float)
            source.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
            let ciInput = CIImage(bitmapData: source.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 8,
                size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: space)
            let filter = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: lut))
            for grain in [FilmGrainParameters.disabled, FilmSource.preset(.kodakPortra400).captureRenderProfile.grain] {
                var p = RealtimePreviewView.Coordinator.PreviewParams(scale: 1, offsetX: 0, offsetY: 0,
                    inputWidth: UInt32(width), inputHeight: UInt32(height), rotation: 0, lutDimension: UInt32(textures.dimension),
                    grainAmount: grain.renderAmount(forLongEdge: CGFloat(width)), grainSize: grain.pixelSize(forLongEdge: CGFloat(width)),
                    grainChroma: grain.chroma, grainSeed: 123, halationAmount: 0, halationRadiusPx: 0, halationHue: 0,
                    bloomAmount: 0, bloomRadiusPx: 0, highlightThreshold: 0.72, headroomAmount: 0, headroomShoulder: 0,
                    chromaticGainR: 1, chromaticGainG: 1, chromaticGainB: 1, chromaticHighlightProtection: 0, grainResponse: 1,
                    materialDensityDimension: Float(material.density.width), materialPrintDimension: Float(material.paper.width),
                    materialFinishDimension: Float(material.finish.width), materialMaximumR: material.maximum.x,
                    materialMaximumG: material.maximum.y, materialMaximumB: material.maximum.z,
                    materialRefineX: material.refinement.x, materialRefineY: material.refinement.y,
                    materialRefineZ: material.refinement.z, materialRefineW: material.refinement.w,
                    materialIdentityFlags: material.identityFlags)
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let first = try XCTUnwrap(command.makeComputeCommandEncoder())
                first.setComputePipelineState(firstPipeline)
                for (i, t) in [input, textures.texture, exposed, energy].enumerated() { first.setTexture(t, index: i) }
                first.setBytes(&p, length: MemoryLayout.size(ofValue: p), index: 0)
                first.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                first.endEncoding()
                let last = try XCTUnwrap(command.makeComputeCommandEncoder())
                last.setComputePipelineState(finishPipeline)
                for (i, t) in [exposed, energy, energy, output, material.density, material.paper, material.finish].enumerated() { last.setTexture(t, index: i) }
                last.setBytes(&p, length: MemoryLayout.size(ofValue: p), index: 0)
                last.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                last.endEncoding()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    command.addCompletedHandler { _ in continuation.resume() }
                    command.commit()
                }
                XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
                var gpu = [Float16](repeating: 0, count: source.count)
                gpu.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
                let still = render(try XCTUnwrap(FilmImagePipeline.stages(for: ciInput, lut: lut, chromaticGain: .one,
                    optics: .disabled, grain: grain, grainSeed: 123)).final)
                let live = render(try XCTUnwrap(FilmImagePipeline.stages(for: ciInput, lut: nil, lutFilter: filter,
                    chromaticGain: .one, optics: .disabled, grain: grain, grainSeed: 123)).final)
                XCTAssertEqual(still, live)
                var maximum: Float = 0
                for i in gpu.indices {
                    // Identical source colors in every row; match Core Image's bottom-up grain coordinates.
                    let row = i / (width * 4), column = i % (width * 4)
                    maximum = max(maximum, abs(Float(gpu[i]) - still[(height - 1 - row) * width * 4 + column]))
                }
                print("material_preview_parity grain=\(grain.amount) maximum=\(maximum)")
                XCTAssertLessThan(maximum, 0.003)
            }
        }
    }
}
