import CoreImage
import XCTest
@testable import JustShoot

final class CurvePhotoComparisonTests: XCTestCase {
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
