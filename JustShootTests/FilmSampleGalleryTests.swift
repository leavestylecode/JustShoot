import CoreImage
import ImageIO
import XCTest
@testable import JustShoot

final class FilmSampleGalleryTests: XCTestCase {
    func testAllScenePreviewsMatchTheCaptureLUTAtDisplayResolution() async throws {
        let space = FilmImagePipeline.colorSpace
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space,
            .cacheIntermediates: false])
        let processor = FilmProcessor()
        let cache = FilmCardImageCache()
        for preset in FilmPreset.allCases {
            let lut = try processor.loadLUT(source: .preset(preset))
            for entry in preset.recommendations {
                let filename = entry.scene.filename
                let preview = await cache.loadImage(imageName: filename, maxPixel: 1024, gradedWith: preset)
                try autoreleasepool {
                    let actual = CIImage(cgImage: try XCTUnwrap(preview?.cgImage))
                    let original = try bundledImage(filename)
                    let expected = try XCTUnwrap(FilmImagePipeline.stages(for: original, lut: lut,
                        chromaticGain: .one, optics: .disabled, grain: .disabled, grainSeed: 1)).graded
                    let label = "\(preset.id) · \(filename)"
                    XCTAssertEqual(actual.extent, expected.extent, label)
                    let pixels = thumbnailPixels(actual, context: context)
                    let reference = thumbnailPixels(expected, context: context)
                    let error = zip(pixels, reference).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                    XCTAssertLessThan(Double(error) / Double(reference.count), 2, label)
                }
            }
        }
    }

    func testOriginalAndPresetVariantsShareOnlyMatchingCacheEntries() async throws {
        let cache = FilmCardImageCache()
        let filename = FilmSampleScene.quilter.filename
        let color = await cache.loadImage(imageName: filename, maxPixel: 600, gradedWith: .kodakPortra400)
        let mono = await cache.loadImage(imageName: filename, maxPixel: 540, gradedWith: .kodakTriX400)
        let original = try XCTUnwrap(cache.cachedImage(imageName: filename, maxPixel: 640))
        let colorImage = try XCTUnwrap(color)
        let monoImage = try XCTUnwrap(mono)
        XCTAssertFalse(original === colorImage)
        XCTAssertFalse(colorImage === monoImage)
        XCTAssertEqual(colorImage.cgImage?.width, 640)
        let revisited = await cache.loadImage(imageName: filename, maxPixel: 640, gradedWith: .kodakPortra400)
        XCTAssertTrue(revisited === colorImage)
    }

    func testEachFilmPairsDistinctRegionalPhotographsWithItsRecommendedScenes() {
        let usa: Set<FilmSampleScene> = [.quilter, .ranch, .roadside, .fair, .diner, .motel,
            .ballpark, .fruitStand, .pinkDiner, .boots, .orchard,
            .haydenSnow, .trinidadSunset, .timesSquareWedding, .yorkvilleClouds]
        let britain: Set<FilmSampleScene> = [.foodStall, .pier, .lambStreet, .cullumStreet, .suttonRain]
        let japan: Set<FilmSampleScene> = [.park, .kimono, .wedding, .festival, .ceremony, .teaMaster,
            .teaPortrait, .wagashi, .bamboo, .seaSunset, .fuji, .shoppingStreet, .asakusa,
            .train, .torii, .fishMarket, .rainCyclist, .shirakawaSnow, .asakusaClouds]
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

    func testWeatherAndWeddingTagsShowTheCorrespondingConditions() {
        let subjects: [FilmSceneTag: Set<FilmSampleScene>] = [
            .sunny: [.asakusa, .train, .pinkDiner, .orchard],
            .cloudy: [.asakusaClouds, .yorkvilleClouds, .fair],
            .rainy: [.rainCyclist, .suttonRain],
            .snow: [.shirakawaSnow, .haydenSnow],
            .sunset: [.seaSunset, .trinidadSunset],
            .night: [.motel],
            .wedding: [.wedding, .timesSquareWedding]
        ]
        for preset in FilmPreset.allCases {
            for entry in preset.recommendations {
                if let candidates = subjects[entry.tag] {
                    XCTAssertTrue(candidates.contains(entry.scene), "\(preset.id) · \(entry.tag) · \(entry.scene)")
                }
            }
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
