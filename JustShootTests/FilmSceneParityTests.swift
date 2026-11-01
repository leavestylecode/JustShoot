import XCTest
import CoreImage
import Metal
@testable import JustShoot

/// Image-wide transform checks. Identical input bytes isolate renderer errors from
/// Apple's different video/RAW development. Optional photographs are SDR fixtures,
/// never presented as paired iPhone RAW calibration or a film colorimetric truth.
final class FilmSceneParityTests: XCTestCase {
    private let space = FilmImagePipeline.colorSpace

    private struct Scene {
        let name: String
        let image: CIImage
    }

    private func referenceColor(_ rgb: SIMD3<Float>, table: UnsafeBufferPointer<Float>, dimension: Int) -> SIMD3<Float> {
        let point = rgb * Float(dimension - 1)
        let lower = SIMD3(Int(floor(point.x)), Int(floor(point.y)), Int(floor(point.z)))
        let fraction = point - SIMD3(Float(lower.x), Float(lower.y), Float(lower.z))
        var result = SIMD3<Float>.zero
        for blue in 0...1 { for green in 0...1 { for red in 0...1 {
            let x = min(lower.x + red, dimension - 1)
            let y = min(lower.y + green, dimension - 1)
            let z = min(lower.z + blue, dimension - 1)
            let weight = (red == 0 ? 1 - fraction.x : fraction.x)
                * (green == 0 ? 1 - fraction.y : fraction.y)
                * (blue == 0 ? 1 - fraction.z : fraction.z)
            let offset = ((z * dimension + y) * dimension + x) * 4
            result += SIMD3(table[offset], table[offset + 1], table[offset + 2]) * weight
        } } }
        return result
    }

    private func stressScenes() -> [Scene] {
        let palettes: [(String, [SIMD3<Float>])] = [
            ("skin", [SIMD3(0.78, 0.59, 0.48), SIMD3(0.55, 0.39, 0.30),
                      SIMD3(0.30, 0.19, 0.12), SIMD3(0.14, 0.09, 0.06)]),
            ("daylight", [SIMD3(0.3, 0.6, 0.95), SIMD3(0.15, 0.45, 0.18),
                          SIMD3(0.98, 0.96, 0.93), SIMD3(0.7, 0.08, 0.04)]),
            ("night", [SIMD3(0.003, 0.006, 0.012), SIMD3(0.02, 0.03, 0.06),
                       SIMD3(1, 0.05, 0.12), SIMD3(0.1, 0.9, 1)])
        ]
        return palettes.map { name, palette in
            let width = 128, height = 64
            var values = [Float](repeating: 1, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let color = palette[y * palette.count / height] * Float(x) / Float(width - 1)
                for channel in 0..<3 { values[(y * width + x) * 4 + channel] = color[channel] }
            } }
            return Scene(name: "stress-" + name, image: CIImage(
                bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) },
                bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                format: .RGBAf, colorSpace: space))
        }
    }

    @MainActor
    func testEveryLookMatchesMetalAcrossSkinDaylightAndNightImages() async throws {
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        var scenes = stressScenes()
        if let directory = ProcessInfo.processInfo.environment["JUSTSHOOT_SCENE_FIXTURES"] {
            for name in ["skin", "daylight", "night"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
                let image = try XCTUnwrap(CIImage(contentsOf: url,
                    options: [.applyOrientationProperty: true]), "Missing SDR fixture: \(url.path)")
                scenes.append(Scene(name: name, image: image))
            }
        }
        let export = ProcessInfo.processInfo.environment["JUSTSHOOT_SCENE_EXPORT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let beforeExport = ProcessInfo.processInfo.environment["JUSTSHOOT_SCENE_BEFORE_EXPORT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        if let beforeExport { try FileManager.default.createDirectory(at: beforeExport, withIntermediateDirectories: true) }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let pipeline = try await device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "previewLUT")))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for preset in FilmPreset.allCases {
            let source = FilmSource.preset(preset)
            let prepared = try await FilmCapturePreparation.shared.displayLUT(source: source, curve: .builtIn(.none))
            // Exercise the RGB refinement, rather than a material's identity
            // carrier. Full material parity is covered separately in FilmMaterialTests.
            let lut: CubeLUT
            if prepared.material != nil {
                let original = try FilmProcessor.shared.loadCubeLUT(resourceName: preset.lutResourceName)
                lut = try FilmLookRefinement.applying(to: original, preset: preset)
            } else {
                lut = CubeLUT(data: prepared.data, dimension: prepared.dimension)
            }
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = .type3D
            descriptor.pixelFormat = .rgba32Float
            descriptor.width = lut.dimension; descriptor.height = lut.dimension; descriptor.depth = lut.dimension
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            let table = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            lut.data.withUnsafeBytes { table.replace(
                region: MTLRegionMake3D(0, 0, 0, lut.dimension, lut.dimension, lut.dimension),
                mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!,
                bytesPerRow: lut.dimension * 16, bytesPerImage: lut.dimension * lut.dimension * 16) }
            for scene in scenes {
                let width = Int(scene.image.extent.width), height = Int(scene.image.extent.height)
                var bytes = [UInt8](repeating: 0, count: width * height * 4)
                context.render(scene.image, toBitmap: &bytes, rowBytes: width * 4,
                    bounds: scene.image.extent, format: .BGRA8, colorSpace: space)
                let quantized = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4,
                    size: CGSize(width: width, height: height), format: .BGRA8, colorSpace: space)
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: width, height: height, mipmapped: false)
                textureDescriptor.storageMode = .shared; textureDescriptor.usage = [.shaderRead, .shaderWrite]
                let input = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
                bytes.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
                textureDescriptor.pixelFormat = .rgba16Float
                let output = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
                textureDescriptor.pixelFormat = .r16Float
                let energy = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
                var params = RealtimePreviewView.Coordinator.PreviewParams(
                    scale: 1, offsetX: 0, offsetY: 0, inputWidth: UInt32(width), inputHeight: UInt32(height),
                    rotation: 0, lutDimension: UInt32(lut.dimension), grainAmount: 0, grainSize: 1,
                    grainChroma: 0, grainSeed: 1, halationAmount: 0, halationRadiusPx: 0, halationHue: 0,
                    bloomAmount: 0, bloomRadiusPx: 0, highlightThreshold: 0.72, headroomAmount: 0,
                    headroomShoulder: 0.7, chromaticGainR: 1, chromaticGainG: 1, chromaticGainB: 1,
                    chromaticHighlightProtection: 0, grainResponse: 0)
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(input, index: 0); encoder.setTexture(table, index: 1)
                encoder.setTexture(output, index: 2); encoder.setTexture(energy, index: 3)
                encoder.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 0)
                encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
                encoder.endEncoding()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    command.addCompletedHandler { _ in continuation.resume() }
                    command.commit()
                }
                XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
                var metal = [Float16](repeating: 0, count: width * height * 4)
                metal.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
                let profile = source.captureRenderProfile
                let stages = try XCTUnwrap(FilmImagePipeline.stages(for: quantized, lut: lut,
                    chromaticGain: .one, optics: profile.optics, grain: profile.grain, grainSeed: 1))
                var ci = [Float](repeating: 0, count: metal.count)
                context.render(stages.graded, toBitmap: &ci, rowBytes: width * 16,
                    bounds: quantized.extent, format: .RGBAf, colorSpace: space)
                var maximum: Float = 0
                var total: Double = 0
                for pixel in 0..<(width * height) { for channel in 0..<3 {
                    let index = pixel * 4 + channel
                    let error = abs(Float(metal[index]) - ci[index])
                    maximum = max(maximum, error); total += Double(error)
                } }
                let mean = total / Double(width * height * 3)
                // Float/half storage and the two GPU interpolation implementations
                // have rounding differences. Bound the whole image below one 8-bit
                // code at any channel and one quarter of a code on average.
                XCTAssertLessThan(maximum, 1 / 255, "\(preset) / \(scene.name)")
                XCTAssertLessThan(mean, 0.25 / 255, "\(preset) / \(scene.name)")
                var metalReferenceMaximum: Float = 0, ciReferenceMaximum: Float = 0
                lut.data.withUnsafeBytes { storage in
                    let tableValues = storage.bindMemory(to: Float.self)
                    for sample in 0..<257 {
                        let pixel = sample * (width * height - 1) / 256
                        let inputRGB = SIMD3(Float(bytes[pixel * 4 + 2]), Float(bytes[pixel * 4 + 1]),
                            Float(bytes[pixel * 4])) / 255
                        let reference = referenceColor(inputRGB, table: tableValues, dimension: lut.dimension)
                        for channel in 0..<3 {
                            let index = pixel * 4 + channel
                            metalReferenceMaximum = max(metalReferenceMaximum, abs(Float(metal[index]) - reference[channel]))
                            ciReferenceMaximum = max(ciReferenceMaximum, abs(ci[index] - reference[channel]))
                        }
                    }
                }
                XCTAssertLessThan(metalReferenceMaximum, 1 / 255, "\(preset) / \(scene.name)")
                XCTAssertLessThan(ciReferenceMaximum, 1 / 255, "\(preset) / \(scene.name)")
                print("scene_preview_parity film=\(preset.rawValue) scene=\(scene.name) maximum=\(maximum) mean=\(mean) metal_reference_max=\(metalReferenceMaximum) ci_reference_max=\(ciReferenceMaximum) pixels=\(width * height)")
                if let export, !scene.name.hasPrefix("stress-") {
                    let png = try XCTUnwrap(context.pngRepresentation(of: stages.final,
                        format: .RGBA8, colorSpace: space))
                    try png.write(to: export.appendingPathComponent("\(preset.rawValue)-\(scene.name).png"), options: .atomic)
                }
                if let beforeExport, !scene.name.hasPrefix("stress-") {
                    let original = try FilmProcessor.shared.loadCubeLUT(resourceName: preset.lutResourceName)
                    let before = try XCTUnwrap(FilmImagePipeline.stages(for: quantized, lut: original,
                        chromaticGain: .one, optics: profile.optics, grain: profile.grain, grainSeed: 1))
                    let png = try XCTUnwrap(context.pngRepresentation(of: before.final,
                        format: .RGBA8, colorSpace: space))
                    try png.write(to: beforeExport.appendingPathComponent("\(preset.rawValue)-\(scene.name).png"), options: .atomic)
                }
            }
        }
    }
}
