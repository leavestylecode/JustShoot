import CoreImage
import ImageIO
import XCTest
@testable import JustShoot

final class ProcessingDiagnosticsTests: XCTestCase {
    func testEnabledDiagnosticsWriteFourDecodableStagesForCapture() async throws {
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try autoreleasepool {
                        let context = CIContext(options: [.priorityRequestLow: true])
                        let input = CIImage(color: CIColor(red: 0.9, green: 0.7, blue: 0.5))
                            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
                        let data = try XCTUnwrap(context.jpegRepresentation(of: input,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]))
                        let preset = FilmPreset.fujiC200
                        let lut = try FilmProcessor.shared.loadCubeLUT(resourceName: preset.lutResourceName)
                        let result = FilmProcessor.shared.applyLUTPreservingMetadata(imageData: data,
                            lutCacheKey: preset.lutResourceName, capturedLUT: lut,
                            grain: preset.renderProfile.grain, optics: preset.filmOptics, diagnosticCaptureID: id)
                        XCTAssertNotNil(result)
                        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        XCTAssertEqual(files.count, 4)
                        for prefix in ["1_original", "2_after_lut", "3_after_optics", "4_after_grain"] {
                            let file = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix(prefix) })
                            let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
                            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                            XCTAssertEqual(image.width, 64)
                            XCTAssertEqual(image.height, 48)
                        }
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
