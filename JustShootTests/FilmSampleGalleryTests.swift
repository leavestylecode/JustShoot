import CoreImage
import ImageIO
import XCTest
@testable import JustShoot

final class FilmSampleGalleryTests: XCTestCase {
    /// Set JUSTSHOOT_SAMPLE_EXPORT to a writable directory on the simulator host
    /// to regenerate the graded HEIC files after a look or source photograph changes.
    func testSamplesMatchTheirBundledFilmLook() throws {
        let export = ProcessInfo.processInfo.environment["JUSTSHOOT_SAMPLE_EXPORT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }

        let space = FilmImagePipeline.colorSpace
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
            .cacheIntermediates: false])
        let processor = FilmProcessor()
        for preset in FilmPreset.allCases {
            let scenes = preset.recommendations.map(\.scene)
            let lut = try processor.loadLUT(source: .preset(preset))
            for scene in scenes {
                try autoreleasepool {
                    let original = try bundledImage(scene.filename())
                    let stages = try XCTUnwrap(FilmImagePipeline.stages(for: original, lut: lut,
                        chromaticGain: .one, optics: .disabled, grain: .disabled, grainSeed: 1))
                    let filename = scene.filename(gradedWith: preset)
                    if let export {
                        try context.writeHEIFRepresentation(of: stages.graded, to: export.appendingPathComponent(filename), format: .RGBA8,
                            colorSpace: space, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.72])
                    } else {
                        let sample = try bundledImage(filename)
                        XCTAssertEqual(sample.extent, original.extent, filename)
                        let actual = thumbnailPixels(sample, context: context)
                        let expected = thumbnailPixels(stages.graded, context: context)
                        let error = zip(actual, expected).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                        XCTAssertLessThan(Double(error) / Double(actual.count), 2, filename)
                    }
                }
            }
        }
    }

    /// Set JUSTSHOOT_RAMP_EXPORT to a plist path to regenerate the guide's tone curves.
    func testFilmToneCurvesMatchTheGradedNeutralRamp() async throws {
        let count = CurveMath.sampleCount
        let input = (0..<count).flatMap { index -> [UInt8] in
            let gray = UInt8(index)
            return [gray, gray, gray, 255]
        }
        let space = FilmImagePipeline.colorSpace
        let image = CIImage(bitmapData: Data(input), bytesPerRow: count * 4,
                            size: CGSize(width: count, height: 1), format: .RGBA8, colorSpace: space)
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false])
        let processor = FilmProcessor()
        let export = ProcessInfo.processInfo.environment["JUSTSHOOT_RAMP_EXPORT"]
        var ramps: [String: Data] = [:]
        for preset in FilmPreset.allCases {
            let bytes = try autoreleasepool {
                let lut = try processor.loadLUT(source: .preset(preset))
                let stages = try XCTUnwrap(FilmImagePipeline.stages(for: image, lut: lut, chromaticGain: .one,
                    optics: .disabled, grain: .disabled, grainSeed: 1))
                var output = [UInt8](repeating: 0, count: count * 4)
                context.render(stages.graded, toBitmap: &output, rowBytes: count * 4, bounds: image.extent,
                               format: .RGBA8, colorSpace: space)
                return output
            }
            if export != nil {
                ramps[preset.id] = Data(bytes)
            } else {
                let preview = try await FilmToneCurveCatalog.shared.preview(for: preset)
                for (channel, table) in [preview.red, preview.green, preview.blue].enumerated() {
                    XCTAssertEqual(table.count, count)
                    for (index, sample) in table.enumerated() {
                        XCTAssertEqual(sample * 255, Float(bytes[index * 4 + channel]), accuracy: 2, preset.id)
                    }
                }
            }
        }
        if let export {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(ramps).write(to: URL(fileURLWithPath: export), options: .atomic)
        }
    }

    func testEachFilmPairsDistinctRegionalPhotographsWithItsRecommendedScenes() {
        let usa: Set<FilmSampleScene> = [.quilter, .ranch, .roadside, .fair, .diner, .motel,
            .ballpark, .fruitStand, .pinkDiner, .hats, .boots, .orchard]
        let britain: Set<FilmSampleScene> = [.foodStall, .borough, .pier, .lambStreet, .cullumStreet]
        let japan: Set<FilmSampleScene> = [.park, .kimono, .wedding, .festival, .ceremony, .teaMaster,
            .teaPortrait, .wagashi, .bamboo, .seaSunset, .hydrangea, .fuji, .shoppingStreet, .asakusa,
            .train, .torii, .fishMarket]
        var used = Set<FilmSampleScene>()
        for preset in FilmPreset.allCases {
            let entries = preset.recommendations
            let scenes = Set(entries.map(\.scene))
            XCTAssertEqual(entries.count, 5, preset.id)
            XCTAssertEqual(scenes.count, 5, preset.id)
            let regionalScenes: Set<FilmSampleScene>
            switch preset.coverDetails.brand {
            case "Fujifilm": regionalScenes = japan
            case "Kodak": regionalScenes = usa
            case "Ilford": regionalScenes = britain
            default:
                XCTFail("Missing regional sample coverage for \(preset.id)")
                continue
            }
            XCTAssertTrue(scenes.isSubset(of: regionalScenes), preset.id)
            used.formUnion(scenes)
        }
        XCTAssertEqual(used, Set(FilmSampleScene.allCases))
        for scene in used {
            var title = scene.title
            title.locale = Locale(identifier: "en")
            let english = String(localized: title)
            title.locale = Locale(identifier: "zh-Hans")
            XCTAssertNotEqual(String(localized: title), english, scene.rawValue)
            XCTAssertNotEqual(english, scene.rawValue)
        }
    }

    private func bundledImage(_ filename: String) throws -> CIImage {
        let url = try XCTUnwrap(Bundle.main.url(forResource: filename, withExtension: nil), filename)
        return try XCTUnwrap(CIImage(contentsOf: url), filename)
    }

    private func thumbnailPixels(_ image: CIImage, context: CIContext) -> [UInt8] {
        let width = 36, height = 24
        let sample = image.samplingLinear().transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / image.extent.width, y: CGFloat(height) / image.extent.height),
            highQualityDownsample: true)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(sample, toBitmap: &bytes, rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace)
        return bytes
    }
}
