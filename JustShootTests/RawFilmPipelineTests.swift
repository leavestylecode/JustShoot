import XCTest
import CoreImage
import ImageIO
import CryptoKit
import CoreLocation
import UIKit
@testable import JustShoot

final class RawFilmPipelineTests: XCTestCase {
    private struct Manifest: Decodable { let stocks: [Stock] }
    private struct Stock: Decodable {
        let resourceName: String
        let binarySHA256: String
        let previewSHA256: String
        let referenceSamples: [Sample]
    }
    private struct Sample: Decodable { let input: [Float]; let output: [Float] }

    private func resource(_ name: String, _ suffix: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: name, withExtension: suffix)))
    }
    private func lut(_ simulation: FujifilmSimulation = .provia) throws -> RawFilmLUT {
        try RawFilmLUT(data: resource(simulation.resourceName, "jsraw"))
    }
    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: resource("RawLUTProvenance", "json"))
    }

    func testAllOfficialSimulationsHaveFrozenVerifiedTablesAndSeparatePreviewCubes() throws {
        let stocks = try manifest().stocks
        XCTAssertEqual(stocks.count, 6)
        XCTAssertEqual(Set(stocks.map(\.resourceName)), Set(FujifilmSimulation.allCases.map(\.resourceName)))
        XCTAssertEqual(Set(stocks.map(\.resourceName)), Set(FilmPreset.allCases.filter { $0.rawSimulation != nil }.map(\.lutResourceName)))
        for stock in stocks {
            let data = try resource(stock.resourceName, "jsraw")
            let raw = try RawFilmLUT(data: data)
            XCTAssertEqual(raw.sha256, stock.binarySHA256)
            XCTAssertEqual(data.count, RawFilmLUT.byteCount)
            let preview = try resource(stock.resourceName, "jslut")
            XCTAssertEqual(SHA256.hash(data: preview).map { String(format: "%02x", $0) }.joined(), stock.previewSHA256)
            XCTAssertEqual(try FilmProcessor().loadCubeLUT(resourceName: stock.resourceName).dimension, 65)
        }
        for preset in FilmPreset.allCases where preset.rawSimulation != nil {
            XCTAssertFalse(preset.renderProfile.grain.isEnabled)
            XCTAssertFalse(preset.renderProfile.optics.isEnabled)
            XCTAssertEqual(preset.renderProfile.effectiveChromatic.responseGain(sceneCCT: 3_200), .one)
        }
    }

    func testActualGPUKernelMatchesIndependentOCIOReferencesIncludingNegativeAndHDRInput() throws {
        let context = CIContext(options: [.workingColorSpace: RawFilmRenderer.linearSpace,
            .workingFormat: CIFormat.RGBAf, .outputColorSpace: FilmImagePipeline.colorSpace,
            .cacheIntermediates: false])
        for stock in try manifest().stocks {
            let raw = try RawFilmLUT(data: resource(stock.resourceName, "jsraw"))
            let samples = stock.referenceSamples
            let input = samples.flatMap { $0.input + [Float(1)] }
            let image = CIImage(bitmapData: input.withUnsafeBufferPointer { Data(buffer: $0) },
                bytesPerRow: input.count * 4, size: CGSize(width: samples.count, height: 1),
                format: .RGBAf, colorSpace: RawFilmRenderer.linearSpace)
            let mapped = try XCTUnwrap(RawFilmRenderer.mapDeveloped(image, lut: raw, recipe: RawCaptureRecipe(lut: raw)))
            var output = [Float](repeating: 0, count: input.count)
            context.render(mapped, toBitmap: &output, rowBytes: output.count * 4,
                bounds: image.extent, format: .RGBAf, colorSpace: FilmImagePipeline.colorSpace)
            var maximumError: Float = 0
            for (index, sample) in samples.enumerated() {
                for channel in 0..<3 {
                    XCTAssertTrue(output[index * 4 + channel].isFinite)
                    maximumError = max(maximumError, abs(output[index * 4 + channel] - sample.output[channel]))
                }
                XCTAssertEqual(output[index * 4 + 3], 1, accuracy: 0.0001)
            }
            XCTAssertLessThan(maximumError, 0.002, stock.resourceName)
            print("raw_lut_reference mode=\(stock.resourceName) samples=\(samples.count) max_error=\(maximumError)")
            // A unit-domain shortcut would collapse every gray above 1 to the same output.
            let high = samples.indices.filter { index in
                let input = samples[index].input
                return input[0] >= 1 && input.dropFirst().allSatisfy { $0 == input[0] }
            }
            if high.count > 1 {
                XCTAssertGreaterThan(abs(output[high.first! * 4] - output[high.last! * 4]), 0.005, stock.resourceName)
            }
        }
    }

    func testMalformedTablesAndUnsupportedRecipesAreRejected() throws {
        let raw = try lut()
        XCTAssertThrowsError(try RawFilmLUT(data: Data(raw.data.dropLast())))
        var corrupt = raw.data
        corrupt[0] = 0
        XCTAssertThrowsError(try RawFilmLUT(data: corrupt))
        corrupt = raw.data
        corrupt.replaceSubrange(16..<20, with: [0, 0, 192, 127]) // NaN
        XCTAssertThrowsError(try RawFilmLUT(data: corrupt))
        var recipe = RawCaptureRecipe(lut: raw)
        recipe.version = 2
        XCTAssertThrowsError(try recipe.validate(lut: raw))
        XCTAssertThrowsError(try RawCaptureRecipe(lut: raw).validate(lut: lut(.velvia)))
    }

    func testAdaptiveRAWRecipeIsVersionedAndLegacyLinearRecipesRemainReadable() throws {
        let table = try lut()
        let recipe = RawCaptureRecipe(lut: table)
        XCTAssertEqual(recipe.version, 3)
        XCTAssertEqual(recipe.inputSpace, .sceneLinearRec2020)
        XCTAssertEqual(try JSONDecoder().decode(RawCaptureRecipe.self,
            from: JSONEncoder().encode(recipe)), recipe)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any])
        json["version"] = 1
        json.removeValue(forKey: "inputSpace")
        let legacy = try JSONDecoder().decode(RawCaptureRecipe.self,
            from: JSONSerialization.data(withJSONObject: json))
        try legacy.validate(lut: table)
        XCTAssertEqual(legacy.version, 1)
        XCTAssertEqual(legacy.resolvedInputSpace, .sceneLinearRec2020)
        let decoder = try XCTUnwrap(CIRAWFilter(imageData: LinearDNGFixture.make(), identifierHint: "com.adobe.raw-image"))
        RawFilmRenderer.configure(decoder, recipe: legacy)
        if decoder.isLocalToneMapSupported { XCTAssertEqual(decoder.localToneMapAmount, 0) }
        var unsupported = recipe
        unsupported.version = 4
        XCTAssertFalse(unsupported.isValid)
    }

    func testRAWSelectionAndDeliveryNeverSilentlySubstituteAProcessedPhoto() {
        let pro = CameraRAWFormat(pixelFormat: 1, kind: .appleProRAW)
        let bayer = CameraRAWFormat(pixelFormat: 2, kind: .bayerRAW)
        XCTAssertEqual(CameraRAWCapturePolicy.select(formats: [bayer, pro], zoom: 3), pro)
        XCTAssertEqual(CameraRAWCapturePolicy.select(formats: [bayer], zoom: 1), bayer)
        XCTAssertNil(CameraRAWCapturePolicy.select(formats: [bayer], zoom: 1.01))
        XCTAssertNil(CameraRAWCapturePolicy.select(formats: [bayer], zoom: 1, outputScale: 2))
        XCTAssertNil(CameraRAWCapturePolicy.select(formats: [], zoom: 1))
        XCTAssertTrue(CameraRAWCapturePolicy.acceptsDelivery(expectsRAW: true, isRAW: true))
        XCTAssertFalse(CameraRAWCapturePolicy.acceptsDelivery(expectsRAW: true, isRAW: false))
        XCTAssertFalse(CameraRAWCapturePolicy.acceptsDelivery(expectsRAW: false, isRAW: true))
    }

    func testProcessedJPEGIsRejectedAndCancelledRAWIsNotRendered() throws {
        let raw = try lut()
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { ctx in
            UIColor.gray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }.jpegData(compressionQuality: 0.9))
        XCTAssertNil(RawFilmRenderer.develop(jpeg, lut: raw, recipe: RawCaptureRecipe(lut: raw)))
        let cancelled = CaptureRenderCancellation()
        cancelled.cancel()
        XCTAssertNil(RawFilmRenderer.develop(LinearDNGFixture.make(), lut: raw,
            recipe: RawCaptureRecipe(lut: raw), cancellation: cancelled))
    }

    func testSceneRAWExposureReferenceIsInvariantToDNGStorageHeadroom() throws {
        // Same scene, stored four stops lower with a compensating DNG baseline.
        // Clearing that baseline incorrectly makes every official look almost black.
        let reference = LinearDNGFixture.make()
        let headroom = LinearDNGFixture.make(baselineExposure: 4)
        let context = CIContext(options: [.workingColorSpace: RawFilmRenderer.linearSpace,
            .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        func pixels(_ image: CIImage) -> [Float] {
            let small = image.transformed(by: CGAffineTransform(scaleX: 0.125, y: 0.125))
            var values = [Float](repeating: 0, count: 32 * 24 * 4)
            context.render(small, toBitmap: &values, rowBytes: 32 * 16,
                bounds: CGRect(x: 0, y: 0, width: 32, height: 24), format: .RGBAf,
                colorSpace: FilmImagePipeline.colorSpace)
            return values
        }
        for simulation in FujifilmSimulation.allCases {
            let table = try lut(simulation)
            let recipe = RawCaptureRecipe(lut: table)
            let expected = pixels(try XCTUnwrap(RawFilmRenderer.develop(reference, lut: table, recipe: recipe)))
            let actual = pixels(try XCTUnwrap(RawFilmRenderer.develop(headroom, lut: table, recipe: recipe)))
            let error = zip(expected, actual).map { abs($0 - $1) }.max()!
            XCTAssertLessThan(error, 0.01, simulation.rawValue)
        }
    }

    func testSyntheticDNGDevelopsThroughOfficialLUTAndEncodesSRGBWithOrientationAndMetadata() throws {
        let raw = try lut()
        let recipe = RawCaptureRecipe(lut: raw)
        let dng = LinearDNGFixture.make(orientation: 6)
        let dngSource = try XCTUnwrap(CGImageSourceCreateWithData(dng as CFData, nil))
        XCTAssertTrue(RawFilmRenderer.isDNG(dngSource), "\(String(describing: CGImageSourceCopyPropertiesAtIndex(dngSource, 0, nil)))")
        let decoder = try XCTUnwrap(CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image"))
        let originalTemperature = decoder.neutralTemperature
        let originalBaseline = decoder.baselineExposure
        RawFilmRenderer.configure(decoder, recipe: recipe)
        XCTAssertEqual(decoder.neutralTemperature, originalTemperature)
        XCTAssertEqual(decoder.boostAmount, 0)
        XCTAssertEqual(decoder.baselineExposure, originalBaseline)
        XCTAssertFalse(decoder.isGamutMappingEnabled)
        let preview = try FilmProcessor().loadCubeLUT(resourceName: FujifilmSimulation.provia.resourceName)
        let location = CLLocation(latitude: 31.2, longitude: 121.5)
        let encoded = try XCTUnwrap(FilmProcessor().applyLUTPreservingMetadata(imageData: dng,
            lutCacheKey: "raw-test", capturedLUT: preview, rawRecipe: recipe, rawLUT: raw,
            location: location, focalLengthIn35mm: 24))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
        XCTAssertNotEqual(CGImageSourceGetType(source) as String?, "com.adobe.raw-image")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 256)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, 1)
        XCTAssertNil(properties[kCGImagePropertyDNGDictionary as String])
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude as String] as? Double), 31.2, accuracy: 0.001)
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int, 24)
    }

    func testSelectedCurveIsAppliedAfterOfficialMappingAndWhiteBalanceIsFrozen() throws {
        let raw = try lut()
        let curve = FilmCurve.builtIn(.crossProcess)
        let recipe = RawCaptureRecipe(lut: raw, curve: curve, temperature: .temperature(4_200), tint: .value(8))
        let decoded = try JSONDecoder().decode(RawCaptureRecipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded, recipe)
        let decoder = try XCTUnwrap(CIRAWFilter(imageData: LinearDNGFixture.make(), identifierHint: "com.adobe.raw-image"))
        RawFilmRenderer.configure(decoder, recipe: decoded)
        XCTAssertEqual(decoder.neutralTemperature, 4_200, accuracy: 0.01)
        XCTAssertEqual(decoder.neutralTint, 8, accuracy: 0.01)
        let stock = try XCTUnwrap(manifest().stocks.first { $0.resourceName == FujifilmSimulation.provia.resourceName })
        let samples = stock.referenceSamples
        let input = samples.flatMap { $0.input + [Float(1)] }
        let image = CIImage(bitmapData: input.withUnsafeBufferPointer { Data(buffer: $0) },
            bytesPerRow: input.count * 4, size: CGSize(width: samples.count, height: 1),
            format: .RGBAf, colorSpace: RawFilmRenderer.linearSpace)
        let mapped = try XCTUnwrap(RawFilmRenderer.mapDeveloped(image, lut: raw, recipe: decoded))
        let context = CIContext(options: [.workingColorSpace: RawFilmRenderer.linearSpace, .workingFormat: CIFormat.RGBAf])
        var output = [Float](repeating: 0, count: input.count)
        context.render(mapped, toBitmap: &output, rowBytes: output.count * 4,
            bounds: image.extent, format: .RGBAf, colorSpace: FilmImagePipeline.colorSpace)
        for (index, sample) in samples.enumerated() {
            let tables = [recipe.redCurve, recipe.greenCurve, recipe.blueCurve]
            for channel in 0..<3 {
                XCTAssertEqual(output[index * 4 + channel], CurveMath.sample(tables[channel], at: sample.output[channel]), accuracy: 0.002)
            }
        }
    }

    func testPublicAppleProRAWDevelopsToSRGBWhenExternalFixtureIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["JUSTSHOOT_RAW_SAMPLE_PATH"] else {
            throw XCTSkip("Set JUSTSHOOT_RAW_SAMPLE_PATH to the documented public iPhone ProRAW fixture")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertTrue(RawFilmRenderer.isDNG(source))
        let raw = try lut()
        let preview = try FilmProcessor().loadCubeLUT(resourceName: FujifilmSimulation.provia.resourceName)
        let decoder = try XCTUnwrap(CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image"))
        let localToneMap = decoder.localToneMapAmount
        let baseline = decoder.baselineExposure
        RawFilmRenderer.configure(decoder, recipe: RawCaptureRecipe(lut: raw))
        XCTAssertEqual(decoder.baselineExposure, baseline)
        XCTAssertEqual(decoder.localToneMapAmount, localToneMap)
        XCTAssertEqual(decoder.boostAmount, 0)
        let rendered = try XCTUnwrap(FilmProcessor().applyLUTPreservingMetadata(imageData: data,
            lutCacheKey: "public-proraw", capturedLUT: preview, rawRecipe: RawCaptureRecipe(lut: raw), rawLUT: raw))
        let renderedSource = try XCTUnwrap(CGImageSourceCreateWithData(rendered as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(renderedSource, 0, nil))
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertGreaterThan(image.width * image.height, 10_000_000)
        XCTAssertFalse(RawFilmRenderer.isDNG(renderedSource))
        if let output = ProcessInfo.processInfo.environment["JUSTSHOOT_RAW_OUTPUT_PATH"] {
            try rendered.write(to: URL(fileURLWithPath: output))
        }
    }

    func testDisplayRAWRetainsAppleRenderingAndAppliesFrozenCubeOnce() throws {
        let cube = try FilmProcessor().loadCubeLUT(resourceName: "KodakPortra400")
        let recipe = RawCaptureRecipe(displayLUT: cube, temperature: .temperature(4_200), tint: .value(8))
        let dng = LinearDNGFixture.make(orientation: 6)
        let reference = try XCTUnwrap(CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image"))
        let raw = try XCTUnwrap(CIRAWFilter(imageData: dng, identifierHint: "com.adobe.raw-image"))
        RawFilmRenderer.configure(raw, recipe: recipe)
        XCTAssertEqual(raw.baselineExposure, reference.baselineExposure)
        XCTAssertEqual(raw.boostAmount, reference.boostAmount)
        XCTAssertEqual(raw.localToneMapAmount, reference.localToneMapAmount)
        XCTAssertEqual(raw.isGamutMappingEnabled, reference.isGamutMappingEnabled)
        XCTAssertEqual(raw.neutralTemperature, 4_200, accuracy: 1)
        XCTAssertEqual(raw.neutralTint, 8, accuracy: 0.1)
        let decoded = try JSONDecoder().decode(RawCaptureRecipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded, recipe)
        try decoded.validate(displayLUT: cube)
        let different = try FilmProcessor().loadCubeLUT(resourceName: "FujiC200")
        XCTAssertThrowsError(try recipe.validate(displayLUT: different))
        XCTAssertNil(FilmProcessor().applyLUTPreservingMetadata(imageData: dng,
            lutCacheKey: "wrong", capturedLUT: different, rawRecipe: recipe))
        let encoded = try XCTUnwrap(FilmProcessor().applyLUTPreservingMetadata(imageData: dng,
            lutCacheKey: "portra-raw", capturedLUT: cube, rawRecipe: recipe))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 256)
    }

    func testUnifiedRAWUsesTheExactPreviewCubeWithoutASecondWhiteBalance() async throws {
        let data = LinearDNGFixture.make()
        let decoder = try XCTUnwrap(CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image"))
        decoder.orientation = .up
        decoder.extendedDynamicRangeAmount = 0
        let input = try XCTUnwrap(decoder.outputImage)
        let context = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace,
            .outputColorSpace: FilmImagePipeline.colorSpace, .workingFormat: CIFormat.RGBAf])
        for preset in FilmPreset.allCases {
            let cube = try await ColorTemperatureLUT.shared.prepare(source: .preset(preset), curve: .builtIn(.none),
                selection: .temperature(5_100), tint: .value(8),
                reference: CameraWhiteBalanceReading(temperature: 4_800, tint: 2))
            let recipe = RawCaptureRecipe(unifiedLUT: cube)
            XCTAssertEqual(recipe.version, 4)
            XCTAssertTrue(recipe.isValid)
            XCTAssertNil(recipe.temperature)
            XCTAssertNil(recipe.tint)
            let raw = try XCTUnwrap(CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image"))
            RawFilmRenderer.configure(raw, recipe: recipe)
            XCTAssertEqual(raw.neutralTemperature, decoder.neutralTemperature)
            XCTAssertEqual(raw.neutralTint, decoder.neutralTint)
            XCTAssertEqual(raw.baselineExposure, decoder.baselineExposure)
            XCTAssertEqual(raw.boostAmount, decoder.boostAmount)
            XCTAssertEqual(raw.localToneMapAmount, decoder.localToneMapAmount)
            XCTAssertEqual(raw.isGamutMappingEnabled, decoder.isGamutMappingEnabled)
            let developed = try XCTUnwrap(RawFilmRenderer.develop(data, recipe: recipe))
            let reference = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: cube)?.applying(to: input))
            let actual = try XCTUnwrap(FilmImagePipeline.LUTFilter(lut: cube)?.applying(to: developed))
            let bounds = CGRect(x: 0, y: 0, width: 256, height: 192)
            var a = [Float](repeating: 0, count: 256 * 192 * 4)
            var b = a
            context.render(reference, toBitmap: &a, rowBytes: 256 * 16, bounds: bounds, format: .RGBAf, colorSpace: FilmImagePipeline.colorSpace)
            context.render(actual, toBitmap: &b, rowBytes: 256 * 16, bounds: bounds, format: .RGBAf, colorSpace: FilmImagePipeline.colorSpace)
            XCTAssertLessThan(zip(a, b).map { abs($0 - $1) }.max() ?? 1, 0.0001, preset.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(RawCaptureRecipe.self, from: JSONEncoder().encode(recipe)), recipe)
        }
    }

    func testDisplayRAWJournalNeedsOnlyItsFrozenCubeAndRetainsLegacyRecipes() throws {
        let cube = try FilmProcessor().loadCubeLUT(resourceName: "KodakPortra400")
        let plan = PhotoCapturePlan(version: 2, format: .appleProRAW, inputSpace: .displaySRGB, approximateLook: false)
        let recipe = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: "portra", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: FilmSource.preset(.kodakPortra400).captureRenderProfile,
            grainSeed: 1, location: nil, lutDimension: cube.dimension, chromaticSceneCCT: nil,
            photoDisplayTime: nil, raw: RawCaptureRecipe(unifiedLUT: cube), plan: plan)
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let job = try journal.stage(recipe: recipe, imageData: LinearDNGFixture.make(), movieURL: nil, lut: cube)
        XCTAssertNil(try journal.rawLUT(for: job))
        let recovered = try XCTUnwrap(journal.recover().first)
        XCTAssertEqual(recovered.recipe.raw, recipe.raw)
        XCTAssertEqual(recovered.recipe.plan, plan)
        XCTAssertEqual(recovered.recipe.withPhotoDisplayTime(1).plan, plan)
        XCTAssertEqual(try journal.lut(for: job).data, cube.data)
        var oldDisplay = recipe
        oldDisplay.raw = RawCaptureRecipe(displayLUT: cube)
        XCTAssertThrowsError(try journal.stage(recipe: oldDisplay, imageData: LinearDNGFixture.make(), movieURL: nil, lut: cube),
            "New plans must not silently reuse the old manual-WB RAW path")
        oldDisplay.plan = PhotoCapturePlan(version: 1, format: .appleProRAW, inputSpace: .displaySRGB, approximateLook: false)
        let oldJournal = CaptureJournal(root: journal.root.appendingPathComponent("legacy"))
        XCTAssertNoThrow(try oldJournal.stage(recipe: oldDisplay, imageData: LinearDNGFixture.make(), movieURL: nil, lut: cube))
        var legacy = recipe
        legacy.raw = nil; legacy.plan = nil
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "raw"); json.removeValue(forKey: "plan")
        let old = try JSONDecoder().decode(CaptureRecipe.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.raw); XCTAssertNil(old.plan)
        XCTAssertThrowsError(try journal.stage(recipe: recipe, imageData: Data("jpeg".utf8), movieURL: nil, lut: cube))
    }

    func testHDRCaptureRendererWritesGainMapAndRotatesBothDevelopments() throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("HDR gain-map encoding requires iOS 18") }
        let lut = try FilmProcessor.shared.loadCubeLUT(resourceName: "FujiC200")
        let recipe = CaptureRecipe(id: UUID(), captureDate: .now, filterName: "hdr-dng", displayLabel: nil,
            focalLength: 24, outputQuality: nil, profile: FilmSource.preset(.fujiC200).captureRenderProfile,
            grainSeed: 1, location: nil, lutDimension: lut.dimension, chromaticSceneCCT: nil,
            photoDisplayTime: nil, raw: RawCaptureRecipe(unifiedLUT: lut),
            plan: .resolve(mode: .hdr, directHDRAvailable: true), lutIntensity: 0)
        let dng = LinearDNGFixture.make(orientation: 6, brightNeutralPatch: true)
        let encoded = try XCTUnwrap(CapturePhotoRenderer.render(source: dng, recipe: recipe,
            lut: lut, rawLUT: nil, grainSeed: recipe.grainSeed))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded as CFData, nil))
        let base = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(base.width, 192)
        XCTAssertEqual(base.height, 256)
        #if targetEnvironment(simulator)
        guard #available(iOS 26.0, *) else { throw XCTSkip("The iOS 18 simulator omits HDR gain maps") }
        #endif
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
            ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap))
    }

    func testJournalFreezesRawRecipeAndTablesAndRecoversDNGWithoutThem() throws {
        let raw = try lut()
        let preview = try FilmProcessor().loadCubeLUT(resourceName: FujifilmSimulation.provia.resourceName)
        let preset = FilmPreset.fujiProvia100F
        let recipe = CaptureRecipe(id: UUID(), captureDate: Date(), filterName: preset.rawValue, displayLabel: preset.displayName,
            focalLength: 24, outputQuality: 0.9, profile: FilmPreset.fujiProvia100F.renderProfile,
            grainSeed: 1, location: nil, lutDimension: preview.dimension, chromaticSceneCCT: nil,
            photoDisplayTime: nil, raw: RawCaptureRecipe(lut: raw))
        let journal = CaptureJournal(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: journal.root) }
        let original = LinearDNGFixture.make()
        let job = try journal.stage(recipe: recipe, imageData: original, movieURL: nil, lut: preview,
            rawLUT: raw, reserved: true, awaitingCaptureCompletion: true)
        XCTAssertEqual(try journal.rawLUT(for: job)?.data, raw.data)
        let recovered = try XCTUnwrap(CaptureJournal(root: journal.root).recover().first)
        XCTAssertEqual(recovered.recipe.filterName, preset.rawValue)
        XCTAssertEqual(recovered.recipe.raw, recipe.raw)
        XCTAssertEqual(recovered.recipe.withPhotoDisplayTime(1).raw, recipe.raw)
        XCTAssertNotNil(CapturePhotoRenderer.render(source: original, recipe: recovered.recipe,
            lut: try journal.lut(for: recovered), rawLUT: try journal.rawLUT(for: recovered), grainSeed: 1))
        XCTAssertThrowsError(try journal.stage(recipe: recipe, imageData: original, movieURL: nil, lut: preview))
        try FileManager.default.removeItem(at: journal.file("raw-lut.bin", for: recipe.id))
        let inventory = try journal.inventory()
        XCTAssertTrue(inventory.jobs.isEmpty)
        let issue = try XCTUnwrap(inventory.issues.first)
        XCTAssertTrue(issue.hasOriginal)
        let exported = try journal.exportOriginal(for: issue)
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        XCTAssertEqual(exported.pathExtension, "dng")
        XCTAssertEqual(try Data(contentsOf: exported), original)
    }
}

/// Minimal uncompressed, three-channel linear DNG for decoder/metadata regression tests.
/// It is synthetic, and cannot validate an iPhone sensor profile or ProRAW capture quality.
enum LinearDNGFixture {
    static func make(orientation: UInt16 = 1, baselineExposure: Int32 = 0, brightNeutralPatch: Bool = false) -> Data {
        func shorts(_ values: [UInt16]) -> Data { values.reduce(into: Data()) { data, value in
            var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        } }
        func longs(_ values: [UInt32]) -> Data { values.reduce(into: Data()) { data, value in
            var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        } }
        struct Entry { let tag: UInt16; let type: UInt16; let count: UInt32; let data: Data }
        let width: UInt32 = 256, height: UInt32 = 192
        let matrix: [Int32] = [32406, -15372, -4986, -9689, 18758, 415, 557, -2040, 10570]
        let matrixData = matrix.reduce(into: Data()) { $0.append(longs([UInt32(bitPattern: $1), 10_000])) }
        var entries: [Entry] = [
            Entry(tag: 254, type: 4, count: 1, data: longs([0])),
            Entry(tag: 256, type: 4, count: 1, data: longs([width])),
            Entry(tag: 257, type: 4, count: 1, data: longs([height])),
            Entry(tag: 258, type: 3, count: 3, data: shorts([16, 16, 16])),
            Entry(tag: 259, type: 3, count: 1, data: shorts([1])),
            Entry(tag: 262, type: 3, count: 1, data: shorts([34892])),
            Entry(tag: 271, type: 2, count: 10, data: Data("JustShoot\0".utf8)),
            Entry(tag: 272, type: 2, count: 10, data: Data("Synthetic\0".utf8)),
            Entry(tag: 273, type: 4, count: 1, data: longs([0])),
            Entry(tag: 274, type: 3, count: 1, data: shorts([orientation])),
            Entry(tag: 277, type: 3, count: 1, data: shorts([3])),
            Entry(tag: 278, type: 4, count: 1, data: longs([height])),
            Entry(tag: 279, type: 4, count: 1, data: longs([width * height * 6])),
            Entry(tag: 284, type: 3, count: 1, data: shorts([1])),
            Entry(tag: 50706, type: 1, count: 4, data: Data([1, 1, 0, 0])),
            Entry(tag: 50707, type: 1, count: 4, data: Data([1, 1, 0, 0])),
            Entry(tag: 50708, type: 2, count: 18, data: Data("JustShootTest DNG\0\0".utf8)),
            Entry(tag: 50717, type: 4, count: 3, data: longs([65535, 65535, 65535])),
            Entry(tag: 50719, type: 4, count: 2, data: longs([0, 0])),
            Entry(tag: 50720, type: 4, count: 2, data: longs([width, height])),
            Entry(tag: 50721, type: 10, count: 9, data: matrixData),
            Entry(tag: 50728, type: 5, count: 3, data: longs([1, 1, 1, 1, 1, 1])),
            Entry(tag: 50730, type: 10, count: 1, data: longs([UInt32(bitPattern: baselineExposure), 1])),
            Entry(tag: 50778, type: 3, count: 1, data: shorts([21]))
        ]
        entries.sort { $0.tag < $1.tag }
        let extraStart = 8 + 2 + entries.count * 12 + 4
        var extra = Data(), directory = Data()
        let pixelsStart = extraStart + entries.filter { $0.data.count > 4 }.reduce(0) { $0 + $1.data.count }
        for entry in entries {
            directory.append(shorts([entry.tag, entry.type])); directory.append(longs([entry.count]))
            if entry.tag == 273 { directory.append(longs([UInt32(pixelsStart)])) }
            else if entry.data.count <= 4 { directory.append(entry.data); directory.append(Data(count: 4 - entry.data.count)) }
            else { directory.append(longs([UInt32(extraStart + extra.count)])); extra.append(entry.data) }
        }
        var result = Data([0x49, 0x49, 42, 0]); result.append(longs([8]))
        result.append(shorts([UInt16(entries.count)])); result.append(directory); result.append(longs([0])); result.append(extra)
        for y in 0..<height { for x in 0..<width {
            let divisor = powf(2, Float(baselineExposure))
            let rgb = brightNeutralPatch
                ? Array(repeating: x < Int(width) / 2 ? 7_500 + y : 61_000 + y, count: 3)
                : [1_000 + x * 200, 1_000 + y * 270, 20_000]
            result.append(shorts(rgb.map {
                UInt16((Float($0) / divisor).rounded())
            }))
        } }
        return result
    }
}
