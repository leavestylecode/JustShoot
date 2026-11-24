import XCTest
import AVFoundation
import CoreImage
import CoreVideo
import Metal
@testable import JustShoot

final class FilmGrainTests: XCTestCase {
    private let space = FilmImagePipeline.colorSpace
    private let seed: UInt32 = 0x12_3456

    private func image(_ colors: [SIMD3<Float>], width: Int, height: Int) -> CIImage {
        var values = [Float](repeating: 1, count: width * height * 4)
        for index in 0..<(width * height) {
            let color = colors[(index % width) % colors.count]
            for channel in 0..<3 { values[index * 4 + channel] = color[channel] }
        }
        return CIImage(bitmapData: values.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: width * 16, size: CGSize(width: width, height: height),
            format: .RGBAf, colorSpace: space)
    }

    private func pixels(_ image: CIImage) -> [Float] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var result = [Float](repeating: 0, count: width * height * 4)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        context.render(image, toBitmap: &result, rowBytes: width * 16,
            bounds: image.extent, format: .RGBAf, colorSpace: space)
        return result
    }

    private func luminance(_ values: [Float]) -> [Float] {
        stride(from: 0, to: values.count, by: 4).map {
            values[$0] * 0.2126 + values[$0 + 1] * 0.7152 + values[$0 + 2] * 0.0722
        }
    }

    private func statistics(_ values: [Float]) -> (mean: Double, deviation: Double) {
        let mean = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
        let variance = values.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(values.count)
        return (mean, sqrt(variance))
    }

    private func retainedTexture(before: [Float], after: [Float],
                                 source: (mean: Double, deviation: Double), outputMean: Double) -> Double {
        let covariance = zip(before, after).reduce(0.0) {
            $0 + (Double($1.0) - source.mean) * (Double($1.1) - outputMean)
        } / Double(before.count)
        return covariance / (source.deviation * source.deviation)
    }

    private var legacy: FilmGrainParameters {
        FilmGrainParameters(amount: 0.046, size: 1.235, chroma: 0.06)
    }

    func testBalancedResponseIsScopedToNewPortraitPresetsAndRoundTrips() throws {
        for preset in FilmPreset.allCases {
            let grain = preset.renderProfile.grain
            if preset == .kodakPortra400 || preset == .fujiPro400H {
                XCTAssertEqual(grain.response, .balanced)
                XCTAssertEqual(grain.amount, 0.04324, accuracy: 0.00001)
                XCTAssertEqual(grain.shaderResponse, 1)
            } else {
                XCTAssertNil(grain.response)
                XCTAssertEqual(grain.shaderResponse, 0)
            }
            let restored = try JSONDecoder().decode(FilmGrainParameters.self, from: JSONEncoder().encode(grain))
            XCTAssertEqual(restored, grain)
        }
        let imported = FilmSource.custom(id: UUID(), displayName: "film", iso: 400, fileName: "film.cube")
        XCTAssertNil(imported.renderProfile.grain.response)
    }

    func testOldRecipeWithoutResponseKeepsFrozenLegacyPixels() throws {
        let json = Data(#"{"amount":0.046,"size":1.235,"chroma":0.06}"#.utf8)
        let decoded = try JSONDecoder().decode(FilmGrainParameters.self, from: json)
        XCTAssertEqual(decoded, legacy)
        XCTAssertNil(decoded.response)
        let source = image([SIMD3(repeating: 0.08)], width: 4000, height: 1)
        let rendered = pixels(FilmGrainRenderer.applying(to: source, parameters: decoded, seed: seed))
        // Frozen output samples from the original 72/28, asymmetric-capacity recipe.
        let expected: [(Int, SIMD3<Float>)] = [
            (0, SIMD3(0.0799161, 0.0799575, 0.0799177)),
            (1, SIMD3(0.0798721, 0.0797843, 0.0797983)),
            (5, SIMD3(0.0922421, 0.0918474, 0.0918604)),
            (17, SIMD3(0.0796650, 0.0797475, 0.0796846)),
            (63, SIMD3(0.0793015, 0.0792172, 0.0793082)),
            (3999, SIMD3(0.0791334, 0.0791408, 0.0791718))
        ]
        for (index, rgb) in expected {
            for channel in 0..<3 {
                XCTAssertEqual(rendered[index * 4 + channel], rgb[channel], accuracy: 0.0003)
            }
        }
    }

    func testBalancedGrainKeepsAverageToneAndReducesShadowTexture() {
        let balanced = FilmPreset.kodakPortra400.renderProfile.grain
        for gray: Float in [0.04, 0.08, 0.14, 0.5, 0.92] {
            // A 4000-pixel long edge exercises the full-photo grain diameter.
            let source = image([SIMD3(repeating: gray)], width: 4000, height: 64)
            let before = statistics(luminance(pixels(FilmGrainRenderer.applying(
                to: source, parameters: legacy, seed: seed))))
            let after = statistics(luminance(pixels(FilmGrainRenderer.applying(
                to: source, parameters: balanced, seed: seed))))
            XCTAssertEqual(after.mean, Double(gray), accuracy: 0.00015,
                "Grain must not add a gray veil or darken highlights")
            XCTAssertGreaterThan(after.deviation, 0.002, "Retain visible texture")
            if gray <= 0.08 {
                XCTAssertGreaterThan(before.mean - Double(gray), 0.002)
                XCTAssertLessThan(after.deviation, before.deviation * 0.80)
                XCTAssertGreaterThan(after.deviation, before.deviation * 0.60)
            } else if gray == 0.14 {
                XCTAssertLessThan(after.deviation, before.deviation * 0.90)
            }
            print("grain_tone_check gray=\(gray) legacy_mean=\(before.mean) balanced_mean=\(after.mean) texture_ratio=\(after.deviation / before.deviation)")
        }
        let skin = SIMD3<Float>(0.55, 0.39, 0.30)
        let source = image([skin], width: 4000, height: 64)
        let rendered = pixels(FilmGrainRenderer.applying(to: source, parameters: balanced, seed: seed))
        for channel in 0..<3 {
            let mean = stride(from: channel, to: rendered.count, by: 4).reduce(0.0) {
                $0 + Double(rendered[$1])
            } / Double(rendered.count / 4)
            XCTAssertEqual(mean, Double(skin[channel]), accuracy: 0.0002)
        }
    }

    func testBalancedGrainReducesFineTextureWhileRetainingMidtoneStructure() {
        let width = 4000
        let source = image([SIMD3(repeating: 0.5)], width: width, height: 64)
        func measure(_ parameters: FilmGrainParameters) -> (deviation: Double, roughness: Double) {
            let values = luminance(pixels(FilmGrainRenderer.applying(to: source, parameters: parameters, seed: seed)))
            let deviation = statistics(values).deviation
            let differences = (0..<values.count).compactMap { index -> Float? in
                index % width == 0 ? nil : values[index] - values[index - 1]
            }
            return (deviation, statistics(differences).deviation / deviation)
        }
        let before = measure(legacy)
        let after = measure(FilmPreset.kodakPortra400.renderProfile.grain)
        XCTAssertLessThan(after.roughness, before.roughness * 0.99)
        XCTAssertGreaterThan(after.deviation, before.deviation * 0.85)
        XCTAssertLessThan(after.deviation, before.deviation * 1.05)
    }

    func testBalancedGrainKeepsBlackWhiteAndSaturatedChannelsInGamut() {
        let levels: [Float] = [0, 0.001, 0.04, 0.5, 0.999, 1]
        let colors = levels.flatMap { red in
            levels.flatMap { green in levels.map { blue in SIMD3(red, green, blue) } }
        }
        let source = image(colors, width: colors.count, height: 32)
        for preset in [FilmPreset.kodakPortra400, .fujiPro400H] {
            for testSeed: UInt32 in [1, seed, .max] {
                let rendered = pixels(FilmGrainRenderer.applying(
                    to: source, parameters: preset.renderProfile.grain, seed: testSeed))
                for index in 0..<(rendered.count / 4) {
                    for channel in 0..<3 {
                        let value = rendered[index * 4 + channel]
                        XCTAssertTrue(value.isFinite)
                        XCTAssertGreaterThanOrEqual(value, 0)
                        XCTAssertLessThanOrEqual(value, 1)
                        let original = colors[index % colors.count][channel]
                        if original == 0 || original == 1 { XCTAssertEqual(value, original, accuracy: 0.00001) }
                    }
                    XCTAssertEqual(rendered[index * 4 + 3], 1)
                }
            }
        }
    }

    func testDisabledBalancedGrainLeavesExtendedRangeUntouched() {
        let source = image([SIMD3(-0.05, 0.5, 1.25)], width: 1, height: 1)
        let disabled = FilmGrainParameters(amount: 0, size: 1, chroma: 0.06, response: .balanced)
        XCTAssertEqual(pixels(FilmGrainRenderer.applying(to: source, parameters: disabled, seed: seed)), pixels(source))
    }

    func testAreaMatchedCaptureRecipeRoundTripsWithoutChangingOldRecipes() throws {
        let current = legacy.forUnifiedCapture
        XCTAssertEqual(current.response, .balancedContinuous)
        XCTAssertEqual(current.shaderResponse, 1)
        XCTAssertEqual(current.renderAmount(forLongEdge: 4_032), legacy.amount)
        XCTAssertLessThan(current.renderAmount(forLongEdge: 1_000), legacy.amount)
        XCTAssertEqual(legacy.renderAmount(forLongEdge: 500), legacy.amount)
        XCTAssertEqual(try JSONDecoder().decode(FilmGrainParameters.self,
            from: JSONEncoder().encode(current)), current)
        XCTAssertEqual(FilmGrainSampling.adjustment(size: 1, longEdge: .nan, response: .balancedContinuous).scale, 0)
        XCTAssertEqual(FilmGrainSampling.adjustment(size: .infinity, longEdge: 1_000, response: .balancedContinuous).scale, 0)
        XCTAssertEqual(current.sampling(forLongEdge: 8_000).scale, 1)
        XCTAssertLessThan(current.sampling(forLongEdge: 64).scale, current.sampling(forLongEdge: 500).scale)
    }

    func testNewSamplingRejoinsNativeScaleAndKeepsFrozenFujifilmResponse() throws {
        let previous = try JSONDecoder().decode(FilmGrainParameters.self,
            from: Data(#"{"amount":0.042,"size":1.7,"chroma":0.025,"response":"fujifilm_fine_v1"}"#.utf8))
        let current = FilmSource.preset(.fujiRawASTIA).captureRenderProfile.grain
        XCTAssertEqual(previous.sampling(forLongEdge: 3_999).scale, 0.851, accuracy: 0.005)
        XCTAssertEqual(previous.sampling(forLongEdge: 1_280).broadOffset, 0)
        for grain in [legacy.forUnifiedCapture, current, FilmSource.preset(.fujiRawACROS).captureRenderProfile.grain] {
            XCTAssertEqual(grain.sampling(forLongEdge: 3_999).scale, 1, accuracy: 0.00001)
            XCTAssertEqual(grain.sampling(forLongEdge: 4_000).scale, 1)
        }
        let preview = current.sampling(forLongEdge: 1_280)
        XCTAssertLessThan(preview.fineOffset, preview.broadOffset)
        let source = image([SIMD3(repeating: 0.5)], width: 4_032, height: 8)
        XCTAssertEqual(pixels(FilmGrainRenderer.applying(to: source, parameters: current, seed: seed)),
                       pixels(FilmGrainRenderer.applying(to: source, parameters: previous, seed: seed)))
    }

    private func horizontalCorrelation(_ values: [Float], width: Int) -> Double {
        let baseline = statistics(values)
        let differences = (1..<values.count).compactMap { index in
            index % width == 0 ? nil : values[index] - values[index - 1]
        }
        let ratio = statistics(differences).deviation / baseline.deviation
        return 1 - 0.5 * ratio * ratio
    }

    func testPreviewTextureVarianceMatchesReducedFullResolutionPhoto() {
        let width = 4_000, height = 128
        let balancedGrains = ([1, 1.235, 2] as [Float]).map { size in
            FilmGrainParameters(amount: 0.046, size: size, chroma: 0.06,
                response: .balancedContinuous)
        }
        let fujifilmGrains = [FilmPreset.fujiRawASTIA, .fujiRawACROS].map {
            FilmSource.preset($0).captureRenderProfile.grain
        }
        for grain in balancedGrains + fujifilmGrains {
            let full = luminance(pixels(FilmGrainRenderer.applying(
                to: image([SIMD3(repeating: 0.5)], width: width, height: height),
                parameters: grain, seed: seed)))
            for reduction in [2, 4, 8] {
                let smallWidth = width / reduction, smallHeight = height / reduction
                var reduced = [Float](repeating: 0, count: smallWidth * smallHeight)
                for y in 0..<height {
                    for x in 0..<width {
                        reduced[(y / reduction) * smallWidth + x / reduction] +=
                            full[y * width + x] / Float(reduction * reduction)
                    }
                }
                let source = image([SIMD3(repeating: 0.5)], width: smallWidth, height: smallHeight)
                let previewPixels = luminance(pixels(FilmGrainRenderer.applying(
                    to: source, parameters: grain, seed: seed)))
                let preview = statistics(previewPixels)
                let reference = statistics(reduced)
                let ratio = preview.deviation / reference.deviation
                XCTAssertEqual(preview.mean, 0.5, accuracy: 0.0003)
                XCTAssertEqual(ratio, 1, accuracy: 0.18,
                    "\(grain.responseIdentifier) should match the variance of a photo reduced to the same size")
                if grain.response == .balancedContinuous {
                    let unfiltered = FilmGrainParameters(amount: grain.amount, size: grain.size,
                        chroma: grain.chroma, response: .balanced)
                    let before = statistics(luminance(pixels(FilmGrainRenderer.applying(
                        to: source, parameters: unfiltered, seed: seed))))
                    XCTAssertLessThan(abs(preview.deviation - reference.deviation),
                        abs(before.deviation - reference.deviation) * 0.40)
                } else {
                    XCTAssertEqual(horizontalCorrelation(previewPixels, width: smallWidth),
                                   horizontalCorrelation(reduced, width: smallWidth), accuracy: 0.12)
                }
                print("grain_area_check response=\(grain.responseIdentifier) size=\(grain.size) reduction=\(reduction) variance_ratio=\(ratio)")
            }
        }
    }

    func testNewCaptureProfilesEnableFineGrainForEveryFujifilmSimulation() throws {
        let old = FilmPreset.kodakPortra400.renderProfile.grain.forUnifiedCapture
        let captured = FilmSource.preset(.kodakPortra400).captureRenderProfile.grain
        XCTAssertGreaterThan(captured.size, old.size)
        XCTAssertEqual(captured.amount, old.amount)
        XCTAssertEqual(captured.chroma, old.chroma)
        for preset in FilmPreset.allCases {
            let source = FilmSource.preset(preset)
            let grain = source.captureRenderProfile.grain
            if preset.rawSimulation != nil {
                XCTAssertTrue(grain.isEnabled)
                XCTAssertEqual(grain.response, .fujifilmFineFiltered)
                XCTAssertEqual(grain.shaderResponse, 2)
                if preset.isMonochrome {
                    XCTAssertEqual(grain.chroma, 0)
                    XCTAssertLessThan(grain.size, FilmSource.preset(.fujiRawASTIA).captureRenderProfile.grain.size)
                } else {
                    XCTAssertGreaterThan(grain.chroma, 0)
                }
            } else if preset != .kodakPortra400 {
                XCTAssertEqual(grain, preset.renderProfile.grain.forUnifiedCapture)
            }
            let recovered = try JSONDecoder().decode(FilmGrainParameters.self,
                from: JSONEncoder().encode(grain))
            XCTAssertEqual(recovered, grain)
        }
        let saved = Data(#"{"amount":0.032,"size":1.5,"chroma":0.04,"response":"balanced_area_v3"}"#.utf8)
        let oldSimulation = try JSONDecoder().decode(FilmGrainParameters.self, from: saved)
        XCTAssertEqual(oldSimulation.shaderResponse, 1)
        XCTAssertEqual(oldSimulation.response, .balancedAreaMatched)
    }

    func testFujifilmGrainFadesThroughTonesAndKeepsFineSpatialTexture() {
        let width = 4_000
        let profile = FilmSource.preset(.fujiRawASTIA).captureRenderProfile
        let previous = FilmGrainParameters(amount: 0.032, size: 1.5, chroma: 0.04,
            response: .balancedAreaMatched)
        func render(_ gray: Float, grain: FilmGrainParameters) -> [Float] {
            let source = image([SIMD3(repeating: gray)], width: width, height: 64)
            return luminance(pixels(FilmGrainRenderer.applying(to: source, parameters: grain, seed: seed)))
        }
        func roughness(_ values: [Float]) -> Double {
            let differences = (1..<values.count).compactMap { index in
                index % width == 0 ? nil : values[index] - values[index - 1]
            }
            return statistics(differences).deviation / statistics(values).deviation
        }

        let midtone = render(0.5, grain: profile.grain)
        let oldMidtone = render(0.5, grain: previous)
        let midtoneDeviation = statistics(midtone).deviation
        XCTAssertGreaterThan(midtoneDeviation, statistics(oldMidtone).deviation)
        XCTAssertLessThan(roughness(midtone), roughness(oldMidtone) * 0.95)
        // Use a half-float-exact shoulder sample so the tone check measures
        // bias from grain, rather than the GPU working format's rounding.
        for (tone, maximum) in [(Float(0.06), 0.15), (0.20, 0.75), (0.84375, 0.5), (0.96, 0.08)] {
            let patch = statistics(render(tone, grain: profile.grain))
            XCTAssertEqual(patch.mean, Double(tone), accuracy: 0.00015)
            XCTAssertGreaterThan(patch.deviation, 0)
            XCTAssertLessThan(patch.deviation, midtoneDeviation * maximum)
        }
        for tone: Float in [0, 1] {
            let patch = statistics(render(tone, grain: profile.grain))
            XCTAssertEqual(patch.mean, Double(tone), accuracy: 0.00001)
            XCTAssertEqual(patch.deviation, 0, accuracy: 0.00001)
        }
    }

    func testUnifiedCaptureTexturePreservesShadowAndSkinMeansForEveryLook() {
        let colors: [SIMD3<Float>] = [SIMD3(repeating: 0.02), SIMD3(repeating: 0.08),
            SIMD3(0.55, 0.39, 0.30), SIMD3(0.30, 0.19, 0.12), SIMD3(repeating: 0.98)]
        for preset in FilmPreset.allCases {
            let grain = FilmSource.preset(preset).captureRenderProfile.grain
            guard grain.isEnabled else { continue }
            for color in colors {
                let output = pixels(FilmGrainRenderer.applying(
                    to: image([color], width: 1_000, height: 32), parameters: grain, seed: seed))
                for channel in 0..<3 {
                    let mean = stride(from: channel, to: output.count, by: 4)
                        .reduce(0.0) { $0 + Double(output[$1]) } / Double(output.count / 4)
                    XCTAssertEqual(mean, Double(color[channel]), accuracy: 0.00025,
                        "\(preset): texture must not add a shadow veil or shift skin color")
                }
            }
        }
    }

    func testPhotoEncodingPreservesFujifilmTextureInMidtones() throws {
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        let grain = FilmSource.preset(.fujiRawASTIA).captureRenderProfile.grain
        let patches: [SIMD3<Float>] = [SIMD3(repeating: 0.5), SIMD3(0.67, 0.49, 0.39), SIMD3(0.38, 0.57, 0.76)]
        for color in patches {
            let input = image([color], width: 4_032, height: 128)
            let textured = FilmGrainRenderer.applying(to: input, parameters: grain, seed: seed)
            let encoded = try XCTUnwrap(PhotoImageEncoder.encode(textured, context: context,
                colorSpace: space, mode: .quality))
            let decoded = try XCTUnwrap(FilmImagePipeline.decodePhoto(encoded.data))
            XCTAssertEqual(decoded.extent, textured.extent)
            let before = luminance(pixels(textured)), after = luminance(pixels(decoded))
            let source = statistics(before), output = statistics(after)
            let retained = retainedTexture(before: before, after: after, source: source, outputMean: output.mean)
            print("grain_photo_codec codec=\(encoded.decision.codec.rawValue) patch=\(color) retained=\(retained)")
            XCTAssertGreaterThan(retained, 0.35)
            XCTAssertEqual(output.mean, source.mean, accuracy: 0.006)
        }
    }

    @MainActor
    func testLiveEncodingMeasuresTextureAtThePairedFrame() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Live capture requires iOS 18") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov"), output = root.appendingPathComponent("rendered.mov")
        let grain = FilmSource.preset(.fujiRawASTIA).captureRenderProfile.grain
        let timestamp = CMTime(value: 4, timescale: 30)
        let seed = self.seed
        let identity = FilmMaterial.identity().cube
        let (rendered, decoded) = try await Task.detached(priority: .utility) {
            try await CapturePipelineTests.makeVideo(at: source, width: 1_280, height: 960)
            let result = try await LivePhotoProcessor.process(sourceURL: source, lutCacheKey: "identity",
                capturedLUT: identity, lutIntensity: CameraCapturePolicy.defaultLUTIntensity, grain: grain,
                grainBaseSeed: seed, photoDisplayTime: timestamp, outputURL: output)
            let input = try await Self.videoFrame(at: timestamp, from: source)
            let decoded = try await Self.videoFrame(at: timestamp, from: output)
            XCTAssertEqual(decoded.extent, input.extent)
            let rendered = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: identity,
                lutIntensity: CameraCapturePolicy.defaultLUTIntensity, chromaticGain: .one,
                optics: .disabled, grain: grain, grainSeed: result.stillGrainSeed)?.final)
            return (rendered, decoded)
        }.value
        let before = luminance(pixels(rendered)), after = luminance(pixels(decoded))
        let reference = statistics(before), encoded = statistics(after)
        let retained = retainedTexture(before: before, after: after, source: reference, outputMean: encoded.mean)
        print("grain_live_codec retained=\(retained) reference_sd=\(reference.deviation) decoded_sd=\(encoded.deviation)")
        XCTAssertTrue(retained.isFinite)
        XCTAssertEqual(encoded.mean, reference.mean, accuracy: 0.02)
    }

    private static func videoFrame(at timestamp: CMTime, from url: URL) async throws -> CIImage {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first),
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), timestamp) == 0,
               let buffer = CMSampleBufferGetImageBuffer(sample) {
                return CIImage(cvPixelBuffer: buffer)
            }
        }
        XCTFail("Video encoder did not provide the requested fixture timestamp")
        throw CocoaError(.fileReadCorruptFile)
    }

    func testLiveFrameMatchesStillWithFrozenGrainSeed() throws {
        let width = 1_280, height = 16
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var pool: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool), kCVReturnSuccess)
        let actualPool = try XCTUnwrap(pool)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, actualPool, &buffer), kCVReturnSuccess)
        let source = try XCTUnwrap(buffer)
        FilmVideoColorSpace.tag(source)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        let fixture = image([SIMD3(repeating: 0.08), SIMD3(0.55, 0.39, 0.30), SIMD3(repeating: 0.9)],
            width: width, height: height)
        context.render(fixture, to: source, bounds: fixture.extent, colorSpace: space)
        for preset in [FilmPreset.kodakPortra400, .fujiPro400H, .fujiRawASTIA, .fujiRawACROS] {
            let profile = preset.rawSimulation == nil ? preset.renderProfile : FilmSource.preset(preset).captureRenderProfile
            let lut = try FilmProcessor().loadCubeLUT(resourceName: preset.lutResourceName)
            let gain = profile.effectiveChromatic.responseGain(sceneCCT: 6_000)
            let frameSeed = FilmGrainRenderer.temporalSeed(base: seed, seconds: 0.75)
            let frame = try XCTUnwrap(LivePhotoProcessor.renderFrame(source, lut: lut, grain: profile.grain,
                optics: profile.optics, chromaticGain: gain, protectChromaticHighlights: true,
                grainSeed: frameSeed, pool: actualPool))
            let still = try XCTUnwrap(FilmImagePipeline.stages(for: CIImage(cvPixelBuffer: source), lut: lut,
                chromaticGain: gain, protectChromaticHighlights: true, optics: profile.optics,
                grain: profile.grain, grainSeed: frameSeed))
            let livePixels = pixels(CIImage(cvPixelBuffer: frame))
            let stillPixels = pixels(still.final)
            for index in livePixels.indices {
                XCTAssertEqual(livePixels[index], stillPixels[index], accuracy: 0.006)
            }
        }
    }

    @MainActor
    func testMetalPreviewFinishMatchesCoreImageAtMatchingGrainCoordinates() throws {
        try assertMetalPreviewMatchesCoreImage(width: 1_280)
        try assertMetalPreviewMatchesCoreImage(width: 4_000)
    }

    @MainActor
    private func assertMetalPreviewMatchesCoreImage(width: Int) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: .main)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "previewFinish")))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let height = 16
        let colors: [SIMD3<Float>] = [SIMD3(repeating: 0.04), SIMD3(repeating: 0.14), SIMD3(repeating: 0.5),
            SIMD3(repeating: 0.92), SIMD3(0.55, 0.39, 0.30), SIMD3(1, 0, 0)]
        let source: [Float16] = (0..<(width * height)).flatMap { index -> [Float16] in
            let color = colors[(index % width) % colors.count]
            return [Float16(color.x), Float16(color.y), Float16(color.z), 1]
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        let graded = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        source.withUnsafeBytes { graded.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
        let energyDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float,
            width: 1, height: 1, mipmapped: false)
        energyDescriptor.storageMode = .shared
        energyDescriptor.usage = .shaderRead
        let energy = try XCTUnwrap(device.makeTexture(descriptor: energyDescriptor))
        [Float16(0)].withUnsafeBytes { energy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 2) }
        let ciSource = CIImage(bitmapData: source.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: width * 8, size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: space)
        let portra = FilmPreset.kodakPortra400.renderProfile.grain
        let cases: [(grain: FilmGrainParameters, intensity: Float)] = [
            (legacy, 1), (portra, 1), (portra.forUnifiedCapture, 1),
            (portra.forUnifiedCapture, CameraCapturePolicy.defaultLUTIntensity),
            (FilmSource.preset(.fujiRawASTIA).captureRenderProfile.grain, CameraCapturePolicy.defaultLUTIntensity),
            (FilmSource.preset(.fujiRawACROS).captureRenderProfile.grain, CameraCapturePolicy.defaultLUTIntensity)
        ]
        for (grain, intensity) in cases {
            let sampling = grain.sampling(forLongEdge: CGFloat(width))
            var params = RealtimePreviewView.Coordinator.PreviewParams(scale: 1, offsetX: 0, offsetY: 0,
                inputWidth: UInt32(width), inputHeight: UInt32(height), rotation: 0, lutDimension: 2,
                grainAmount: grain.renderAmount(forLongEdge: CGFloat(width)), grainSize: grain.pixelSize(forLongEdge: CGFloat(width)),
                grainChroma: grain.chroma, grainSeed: seed,
                halationAmount: 0, halationRadiusPx: 0, halationHue: 0,
                bloomAmount: 0, bloomRadiusPx: 0, highlightThreshold: 0.72,
                headroomAmount: 0, headroomShoulder: 0.7,
                chromaticGainR: 1, chromaticGainG: 1, chromaticGainB: 1,
                chromaticHighlightProtection: 0, grainResponse: grain.shaderResponse, lutIntensity: intensity,
                grainBroadOffset: sampling.broadOffset, grainFineOffset: sampling.fineOffset,
                grainFineWeight: sampling.fineWeight)
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(graded, index: 0)
            encoder.setTexture(energy, index: 1)
            encoder.setTexture(energy, index: 2)
            encoder.setTexture(output, index: 3)
            encoder.setTexture(graded, index: 7)
            encoder.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 0)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
            var preview = [Float16](repeating: 0, count: source.count)
            preview.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
            let still = pixels(FilmGrainRenderer.applying(to: ciSource, parameters: grain, seed: seed))
            // Core Image destination coordinates start at the bottom; Metal gid
            // starts at the top. Rows have identical source colors so reversing
            // readback rows compares the same grain coordinates and source RGB.
            let maximumError = preview.indices.map { index -> Float in
                let row = index / (width * 4), column = index % (width * 4)
                let full = still[(height - 1 - row) * width * 4 + column]
                let original = Float(source[index])
                return abs(Float(preview[index]) - (original + (full - original) * intensity))
            }.max() ?? 0
            print("grain_preview_check response=\(grain.responseIdentifier) maximum_error=\(maximumError)")
            XCTAssertLessThan(maximumError, 0.0015, "Preview and export must share the same pattern and response")
        }
    }
}
