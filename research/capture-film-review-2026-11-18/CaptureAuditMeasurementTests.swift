// One-off measurement for REVIEW.txt. To reproduce, place a copy in JustShootTests
// and run CaptureAuditMeasurementTests on the simulator named in the review.
import CoreImage
import XCTest
@testable import JustShoot

final class CaptureAuditMeasurementTests: XCTestCase {
    func testMeasureMidtoneGrainBeforeAndAfterPhotoEncoding() throws {
        let space = FilmImagePipeline.colorSpace
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space, .cacheIntermediates: false])
        let bounds = CGRect(x: 0, y: 0, width: 4096, height: 256)
        let input = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: space)!)
            .cropped(to: bounds)
        let region = CGRect(x: 1536, y: 64, width: 1024, height: 128)
        func deviations(_ image: CIImage) -> [Double] {
            let w = Int(region.width), h = Int(region.height)
            var pixels = [Float](repeating: 0, count: w * h * 4)
            context.render(image, toBitmap: &pixels, rowBytes: w * 16, bounds: region,
                format: .RGBAf, colorSpace: space)
            return [1, 4].map { factor in
                var sum = 0.0, squares = 0.0
                for y in stride(from: 0, to: h, by: factor) {
                    for x in stride(from: 0, to: w, by: factor) {
                        var bin = 0.0
                        for j in 0..<factor {
                            for i in 0..<factor {
                                let k = ((y + j) * w + x + i) * 4
                                bin += 0.2126 * Double(pixels[k]) + 0.7152 * Double(pixels[k + 1])
                                    + 0.0722 * Double(pixels[k + 2])
                            }
                        }
                        bin /= Double(factor * factor)
                        sum += bin
                        squares += bin * bin
                    }
                }
                let count = Double((w / factor) * (h / factor))
                return 1023 * sqrt(max(0, squares / count - pow(sum / count, 2)))
            }
        }
        for preset in [FilmPreset.kodakPortra400, .kodakGold200, .kodakTriX400, .fujiRawClassicChrome] {
            try autoreleasepool {
                let source = FilmSource.preset(preset)
                let profile = source.captureRenderProfile
                let lut = try FilmProcessor.shared.loadLUT(source: source)
                let stages = try XCTUnwrap(FilmImagePipeline.stages(for: input, lut: lut, chromaticGain: .one,
                    optics: profile.optics, grain: profile.grain, grainSeed: 123))
                let output = try XCTUnwrap(PhotoImageEncoder.encode(stages.final, context: context,
                    colorSpace: space, mode: .quality))
                let decoded = try XCTUnwrap(PhotoInputDecoder.decode(output.data))
                print("capture_audit_measurement film=\(preset.rawValue) codec=\(output.decision.codec) quality=\(output.decision.quality) pre=\(deviations(stages.final)) post=\(deviations(decoded))")
            }
        }
    }
}
