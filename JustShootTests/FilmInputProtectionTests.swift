import XCTest
import CoreImage
import CoreVideo
import Metal
@testable import JustShoot

final class FilmInputProtectionTests: XCTestCase {
    private let space = FilmImagePipeline.colorSpace

    private func image(_ pixels: [SIMD3<Float>]) -> CIImage {
        let values: [Float] = pixels.flatMap { pixel -> [Float] in [pixel.x, pixel.y, pixel.z, 1] }
        return CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) },
                       bytesPerRow: pixels.count * 16, size: CGSize(width: pixels.count, height: 1),
                       format: .RGBAf, colorSpace: space)
    }

    private func pixels(_ image: CIImage) -> [SIMD3<Float>] {
        let count = Int(image.extent.width)
        var values = [Float](repeating: 0, count: count * 4)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        context.render(image, toBitmap: &values, rowBytes: count * 16, bounds: image.extent,
                       format: .RGBAf, colorSpace: space)
        return (0..<count).map { SIMD3(values[$0 * 4], values[$0 * 4 + 1], values[$0 * 4 + 2]) }
    }

    private func identity() throws -> CubeLUT {
        let text = "LUT_3D_SIZE 2\n" + (0...1).flatMap { blue in
            (0...1).flatMap { green in (0...1).map { red in "\(red) \(green) \(blue)" } }
        }.joined(separator: "\n")
        return try CubeLUT.parse(text)
    }

    private func luma(_ rgb: SIMD3<Float>) -> Float {
        rgb.x * 0.2126 + rgb.y * 0.7152 + rgb.z * 0.0722
    }

    func testProtectedHighlightsStayInsideLUTAndRetainChannelGradients() throws {
        let ramp: [Float] = [0.85, 0.90, 0.95, 1.0]
        let input = image(ramp.map { SIMD3<Float>(repeating: $0) })
        let gains = [
            FilmChromaticResponseParameters(nativeCCT: 3_200, strength: 0.60).responseGain(sceneCCT: 5_500),
            FilmPreset.kodakPortra400.chromaticResponse.responseGain(sceneCCT: 3_200)
        ]
        for gain in gains {
            let legacy = pixels(FilmChromaticRenderer.applying(to: input, gain: gain))
            XCTAssertTrue(legacy.contains { max($0.x, $0.y, $0.z) > 1.02 }, "Fixture must exercise the original overflow")
            let stages = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: identity(),
                chromaticGain: gain, protectChromaticHighlights: true,
                optics: .disabled, grain: .disabled, grainSeed: 1))
            let output = pixels(stages.graded)
            let gained = pixels(FilmChromaticRenderer.applying(to: input, gain: gain, protectHighlights: true))
            for pixel in gained {
                for channel in [pixel.x, pixel.y, pixel.z] {
                    XCTAssertGreaterThanOrEqual(channel, -0.0001)
                    XCTAssertLessThanOrEqual(channel, 1.0001)
                }
            }
            let boostedChannel = gain.x > gain.z ? 0 : 2
            for index in 1..<output.count {
                XCTAssertGreaterThan(luma(output[index]) - luma(output[index - 1]), 0.005)
                XCTAssertGreaterThan(output[index][boostedChannel] - output[index - 1][boostedChannel], 0.0002,
                                     "The boosted channel must not flatten at the LUT edge")
            }
        }
    }

    func testProtectionLeavesSkinMidtonesAndUnitGainUnchanged() {
        let source = image([SIMD3(0.55, 0.39, 0.30), SIMD3(0.68, 0.49, 0.39), SIMD3(0.40, 0.27, 0.22),
                            SIMD3(0.0001, 0.0002, 0.0003)])
        for temperature: Float in [3_200, 5_500, 7_500] {
            let gain = FilmPreset.kodakPortra400.chromaticResponse.responseGain(sceneCCT: temperature)
            let legacy = pixels(FilmChromaticRenderer.applying(to: source, gain: gain))
            let protected = pixels(FilmChromaticRenderer.applying(to: source, gain: gain, protectHighlights: true))
            for (lhs, rhs) in zip(legacy, protected) {
                for channel in 0..<3 { XCTAssertEqual(lhs[channel], rhs[channel], accuracy: 0.0005) }
            }
        }
        let extended = image([SIMD3(-0.05, 0.5, 1.25)])
        let unit = FilmChromaticRenderer.applying(to: extended, gain: .one, protectHighlights: true)
        for channel in 0..<3 { XCTAssertEqual(pixels(unit)[0][channel], pixels(extended)[0][channel], accuracy: 0.0001) }
    }

    func testProtectionApproachesIdentityAsGainApproachesOne() {
        let source = image([SIMD3<Float>(repeating: 0.98), SIMD3(0.4, 0.7, 1)])
        let output = pixels(FilmChromaticRenderer.applying(to: source, gain: SIMD3(1, 1, 1.001), protectHighlights: true))
        for (lhs, rhs) in zip(output, pixels(source)) {
            for channel in 0..<3 { XCTAssertEqual(lhs[channel], rhs[channel], accuracy: 0.002) }
        }
    }

    func testLegacyNearUnitGainRetainsUnmodifiedPixels() {
        let source = image([SIMD3(0.02, 0.30, 0.70), SIMD3(0.55, 0.39, 0.30),
                            SIMD3(-0.05, 0.5, 1.25)])
        let expected = pixels(source)
        for delta: Float in [0.0002, 0.0004] {
            let legacy = FilmChromaticRenderer.applying(to: source,
                gain: SIMD3(1 + delta, 1 - delta, 1 + delta), protectHighlights: false)
            XCTAssertEqual(pixels(legacy), expected,
                "Old recipes must retain the original near-unit bypass, including extended-range pixels")
        }
    }

    func testProtectedColorVolumeIsFiniteAndInGamutForPresetTemperatureExtremes() {
        let levels: [Float] = [0, 0.2, 0.5, 0.8, 0.95, 1]
        let source = image(levels.flatMap { r in levels.flatMap { g in levels.map { b in SIMD3(r, g, b) } } })
        for preset in FilmPreset.allCases {
            for temperature: Float in [2_000, 3_200, 5_500, 8_000, 15_000] {
                let gain = preset.chromaticResponse.responseGain(sceneCCT: temperature)
                let output = pixels(FilmChromaticRenderer.applying(to: source, gain: gain, protectHighlights: true))
                XCTAssertEqual(output.count, 216)
                for pixel in output {
                    for channel in [pixel.x, pixel.y, pixel.z] {
                        XCTAssertTrue(channel.isFinite)
                        XCTAssertGreaterThanOrEqual(channel, -0.0002)
                        XCTAssertLessThanOrEqual(channel, 1.0002)
                    }
                }
            }
        }
    }

    func testLiveFrameMatchesStillGraphWithProtectedHighlights() throws {
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 4, kCVPixelBufferHeightKey as String: 1,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool), kCVReturnSuccess)
        let actualPool = try XCTUnwrap(pool)
        var source: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, actualPool, &source), kCVReturnSuccess)
        let buffer = try XCTUnwrap(source)
        FilmVideoColorSpace.tag(buffer)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        context.render(image([0.85, 0.9, 0.95, 1].map { SIMD3<Float>(repeating: $0) }), to: buffer,
                       bounds: CGRect(x: 0, y: 0, width: 4, height: 1), colorSpace: space)
        let lut = try FilmProcessor().loadCubeLUT(resourceName: FilmPreset.kodakPortra400.lutResourceName)
        let gain = FilmPreset.kodakPortra400.chromaticResponse.responseGain(sceneCCT: 3_200)
        let frame = try XCTUnwrap(LivePhotoProcessor.renderFrame(buffer, lut: lut, grain: .disabled,
            optics: .disabled, chromaticGain: gain, protectChromaticHighlights: true, grainSeed: 1, pool: actualPool))
        let still = try XCTUnwrap(FilmImagePipeline.stages(for: CIImage(cvPixelBuffer: buffer), lut: lut,
            chromaticGain: gain, protectChromaticHighlights: true, optics: .disabled, grain: .disabled, grainSeed: 1))
        let livePixels = pixels(CIImage(cvPixelBuffer: frame))
        for (lhs, rhs) in zip(livePixels, pixels(still.final)) {
            for channel in 0..<3 { XCTAssertEqual(lhs[channel], rhs[channel], accuracy: 0.006) }
        }
    }

    @MainActor
    func testMetalPreviewMatchesCoreImageForProtectedAndLegacyRecipes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let function = try XCTUnwrap(library.makeFunction(name: "previewLUT"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        // Half precision is the actual preview input/output format.
        let colors: [SIMD3<Float>] = [SIMD3(0.62, 0.44, 0.35), SIMD3(repeating: 0.85),
            SIMD3(repeating: 0.95), SIMD3(repeating: 1), SIMD3(0.3, 0.65, 0.95)]
        let halfPixels: [Float16] = colors.flatMap { pixel -> [Float16] in
            [Float16(pixel.x), Float16(pixel.y), Float16(pixel.z), 1]
        }
        let sourceColors = colors.map { SIMD3(Float(Float16($0.x)), Float(Float16($0.y)), Float(Float16($0.z))) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: colors.count, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        halfPixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, colors.count, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: colors.count * 8) }
        descriptor.pixelFormat = .r16Float
        let energy = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        for preset in FilmPreset.allCases {
            let lut = try FilmProcessor().loadCubeLUT(resourceName: preset.lutResourceName)
            let lutDescriptor = MTLTextureDescriptor()
            lutDescriptor.textureType = .type3D
            lutDescriptor.pixelFormat = .rgba32Float
            lutDescriptor.width = lut.dimension
            lutDescriptor.height = lut.dimension
            lutDescriptor.depth = lut.dimension
            lutDescriptor.storageMode = .shared
            lutDescriptor.usage = .shaderRead
            let lutTexture = try XCTUnwrap(device.makeTexture(descriptor: lutDescriptor))
            lut.data.withUnsafeBytes { lutTexture.replace(region: MTLRegionMake3D(0, 0, 0, lut.dimension, lut.dimension, lut.dimension),
                mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!, bytesPerRow: lut.dimension * 16,
                bytesPerImage: lut.dimension * lut.dimension * 16) }
            let gain = preset.chromaticResponse.responseGain(sceneCCT: 3_200)
            for protection in [false, true] {
                var params = RealtimePreviewView.Coordinator.PreviewParams(scale: 1, offsetX: 0, offsetY: 0,
                    inputWidth: UInt32(colors.count), inputHeight: 1, rotation: 0, lutDimension: UInt32(lut.dimension),
                    grainAmount: 0, grainSize: 1, grainChroma: 0, grainSeed: 1,
                    halationAmount: 0, halationRadiusPx: 0, halationHue: 0,
                    bloomAmount: 0, bloomRadiusPx: 0, highlightThreshold: 0.72,
                    headroomAmount: 0, headroomShoulder: 0.7,
                    chromaticGainR: gain.x, chromaticGainG: gain.y, chromaticGainB: gain.z,
                    chromaticHighlightProtection: protection ? 1 : 0, grainResponse: 0)
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(input, index: 0)
                encoder.setTexture(lutTexture, index: 1)
                encoder.setTexture(output, index: 2)
                encoder.setTexture(energy, index: 3)
                encoder.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 0)
                encoder.dispatchThreads(MTLSize(width: colors.count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
                var preview = [Float16](repeating: 0, count: colors.count * 4)
                preview.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: colors.count * 8,
                    from: MTLRegionMake2D(0, 0, colors.count, 1), mipmapLevel: 0) }
                let still = try XCTUnwrap(FilmImagePipeline.stages(for: image(sourceColors), lut: lut,
                    chromaticGain: gain, protectChromaticHighlights: protection,
                    optics: .disabled, grain: .disabled, grainSeed: 1))
                for (index, color) in pixels(still.graded).enumerated() {
                    for channel in 0..<3 {
                        XCTAssertEqual(Float(preview[index * 4 + channel]), color[channel], accuracy: 0.003)
                    }
                }
            }
        }
    }
}
