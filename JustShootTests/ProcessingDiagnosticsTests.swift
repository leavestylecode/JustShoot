import CoreImage
import ImageIO
import XCTest
@testable import JustShoot

final class ProcessingDiagnosticsTests: XCTestCase {
    func testEnabledDiagnosticsIncludeSDRInputAndStageMetrics() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "processingStageDiagnostics")
        defaults.set(true, forKey: "processingStageDiagnostics")
        let id = UUID()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProcessingDiagnostics").appendingPathComponent(id.uuidString)
        defer {
            if let previous { defaults.set(previous, forKey: "processingStageDiagnostics") }
            else { defaults.removeObject(forKey: "processingStageDiagnostics") }
            try? FileManager.default.removeItem(at: directory)
        }
        let work = BlockingImageWork(maximumConcurrentOperations: 1, label: "com.justshoot.test-diagnostics")
        let result = await work.run { () -> Result<Void, any Error>? in
            Result {
                try autoreleasepool {
                    let context = CIContext(options: [.priorityRequestLow: true])
                    let input = CIImage(color: CIColor(red: 0.9, green: 0.7, blue: 0.5))
                        .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
                    let data = try XCTUnwrap(context.jpegRepresentation(of: input,
                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]))
                    let preset = FilmPreset.fujiC200
                    // Keep this fixture's rendering context independent of other tests' caches.
                    let processor = FilmProcessor()
                    let lut = try processor.loadCubeLUT(resourceName: preset.lutResourceName)
                    let result = processor.applyLUTPreservingMetadata(imageData: data,
                        lutCacheKey: preset.lutResourceName, capturedLUT: lut,
                        grain: preset.renderProfile.grain, optics: preset.filmOptics, diagnosticCaptureID: id)
                    XCTAssertNotNil(result)
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    XCTAssertEqual(files.count, 6)
                    XCTAssertTrue(files.contains { $0.lastPathComponent == "stage_metrics.json" })
                    for prefix in ["1_original", "1_input_sdr", "2_after_lut", "3_after_optics", "4_after_grain"] {
                        let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix(prefix) })
                        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
                        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                        XCTAssertEqual(image.width, 64)
                        XCTAssertEqual(image.height, 48)
                    }
                }
            }
        }
        try XCTUnwrap(result).get()
    }

    func testStageStatisticsSeparateShadowAndHighlightChanges() throws {
        let context = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace])
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let black = CIImage(color: .black).cropped(to: rect)
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 16, width: 32, height: 16))
        let metrics = CaptureComparisonDiagnostics.statistics(white.composited(over: black), context: context)
        XCTAssertEqual(metrics.lumaP10, 0, accuracy: 0.001)
        XCTAssertEqual(metrics.lumaP90, 1, accuracy: 0.001)
        for mean in metrics.meanRGB { XCTAssertEqual(mean, 0.5, accuracy: 0.001) }
        XCTAssertEqual(try JSONDecoder().decode(CaptureComparisonDiagnostics.Statistics.self,
            from: JSONEncoder().encode(metrics)), metrics)
    }
}
