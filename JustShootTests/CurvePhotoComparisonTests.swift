import CoreImage
import XCTest
@testable import JustShoot

final class CurvePhotoComparisonTests: XCTestCase {
    func testEverySceneComparesTheFilmLUTWithTheCurveAppliedToThatSameImage() async throws {
        let scenes = CurvePhotoComparison.ReferenceScene.allCases
        XCTAssertEqual(scenes, [.street, .landscape, .portrait])
        XCTAssertEqual(Set(scenes.map { $0.photo.filename }).count, scenes.count)
        let context = FilmProcessor.shared.renderingContext()
        func pixels(_ image: CGImage) -> [UInt8] {
            let size = CGSize(width: 24, height: 16)
            let thumbnail = CIImage(cgImage: image).transformed(by: CGAffineTransform(
                scaleX: size.width / CGFloat(image.width), y: size.height / CGFloat(image.height)))
            var bytes = [UInt8](repeating: 0, count: 24 * 16 * 4)
            context.render(thumbnail, toBitmap: &bytes, rowBytes: 24 * 4,
                bounds: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: FilmImagePipeline.colorSpace)
            return bytes
        }

        for scene in scenes {
            let image = await FilmCardImageCache.shared.loadImage(imageName: scene.photo.filename, maxPixel: 1024)
            let original = try XCTUnwrap(image?.cgImage, scene.photo.filename)
            XCTAssertEqual(Double(original.width) / Double(original.height), 1.5, accuracy: 0.01)
            let film = try XCTUnwrap(FilmProcessor.shared.gradedPreview(original, preset: .kodakPortra400))
            let withCurve = try XCTUnwrap(FilmProcessor.shared.gradedPreview(film, curve: .builtIn(.fadedS)))
            let sample = await CurvePhotoComparison.Sample.load(scene: scene, look: .preset(.fadedS))
            let baseline = try XCTUnwrap(sample?.filmOnly.cgImage)
            let adjusted = try XCTUnwrap(sample?.filmWithCurve?.cgImage)
            XCTAssertEqual(baseline.width, original.width)
            XCTAssertEqual(baseline.height, original.height)
            XCTAssertEqual(adjusted.width, original.width)
            XCTAssertEqual(adjusted.height, original.height)
            XCTAssertNotEqual(pixels(original), pixels(film))
            XCTAssertEqual(pixels(baseline), pixels(film))
            XCTAssertEqual(pixels(adjusted), pixels(withCurve))
        }
    }

    func testNeutralDraftShowsJustTheLUTReference() async throws {
        let loaded = await CurvePhotoComparison.Sample.load(scene: .portrait, look: .draft(CustomFilmCurve(name: "Test")))
        let sample = try XCTUnwrap(loaded)
        XCTAssertNotNil(sample.filmOnly.cgImage)
        XCTAssertNil(sample.filmWithCurve)
    }

    func testSamplePixelsFollowTheSameRGBTablesAsTheCurveGraph() throws {
        let space = FilmImagePipeline.colorSpace
        let context = CIContext(options: [.workingColorSpace: space])
        let width = 256
        var pixels = [UInt8]()
        for index in 0..<width {
            pixels.append(contentsOf: [UInt8(index), UInt8(255 - index), UInt8((index + 60) % 256), 255])
        }
        let ramp = CIImage(bitmapData: Data(pixels), bytesPerRow: width * 4,
            size: CGSize(width: width, height: 1), format: .RGBA8, colorSpace: space)
        let input = try XCTUnwrap(context.createCGImage(ramp, from: ramp.extent, format: .RGBA8, colorSpace: space))

        var draft = CustomFilmCurve(name: "Split tones")
        draft.applyTemplate(.fadedS)
        draft.bluePoints = CurveMath.points([(0, 0.08), (0.5, 0.38), (1, 0.94)])
        let curves = CurvePreset.allCases.map(FilmCurve.builtIn) + [draft.filmCurve]
        for curve in curves {
            let output = try XCTUnwrap(FilmProcessor.shared.gradedPreview(input, curve: curve))
            var actual = [UInt8](repeating: 0, count: pixels.count)
            context.render(CIImage(cgImage: output), toBitmap: &actual, rowBytes: width * 4,
                bounds: ramp.extent, format: .RGBA8, colorSpace: space)
            let tables = [curve.previewData.red, curve.previewData.green, curve.previewData.blue]
            var maximumError = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                for channel in 0..<3 {
                    let expected = Int((255 * tables[channel][Int(pixels[offset + channel])]).rounded())
                    maximumError = max(maximumError, abs(Int(actual[offset + channel]) - expected))
                }
            }
            XCTAssertLessThanOrEqual(maximumError, 2, curve.displayName)
        }
    }

    func testOnlyToneEditsInvalidateTheDraftSample() {
        var draft = CustomFilmCurve(name: "Test")
        let before = CurvePhotoComparison.Look.draft(draft)
        draft.name = "Renamed"
        XCTAssertEqual(before, .draft(draft))
        draft.applyTemplate(.crossProcess)
        XCTAssertNotEqual(before, .draft(draft))
    }
}
