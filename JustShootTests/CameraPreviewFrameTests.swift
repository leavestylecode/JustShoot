import CoreImage
import CoreVideo
import XCTest
@testable import JustShoot

final class CameraPreviewFrameTests: XCTestCase {
    func testPortraitRotationAndBoundedSizePreserveViewfinderAspect() throws {
        let frame = try frame(rotation: 1, crop: 1, outputSize: CGSize(width: 3, height: 4))
        let image = frame.inputImage(maximumPixel: 4)
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 3, height: 4))
    }

    func testAspectFillAndZoomCropKeepTheCenterOfTheRenderedFrame() throws {
        // Eight columns: red edges, green center. A square aspect-fill removes
        // the edges; extra digital zoom must remain centered within that crop.
        let context = CIContext(options: [.workingColorSpace: FilmImagePipeline.colorSpace])
        for crop: CGFloat in [1, 2] {
            let image = try frame(rotation: 0, crop: crop, outputSize: CGSize(width: 1, height: 1))
                .inputImage(maximumPixel: 8)
            XCTAssertEqual(image.extent.width, 4 / crop)
            XCTAssertEqual(image.extent.height, 4 / crop)
            var sample = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &sample, rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                colorSpace: FilmImagePipeline.colorSpace)
            XCTAssertLessThan(sample[0], 2)
            XCTAssertGreaterThan(sample[1], 253)
        }
    }

    func testCaptureRequiresThePresentedFrameFromTheCurrentSettledFocalRequest() throws {
        var captured = try frame(rotation: 1, crop: 2, outputSize: CGSize(width: 3, height: 4))
        captured.focalSequence = 7
        captured.sourceRevision = 3
        func permits(_ candidate: CameraPreviewFrame, generation: UInt64 = 1, sequence: UInt64 = 7,
                     revision: UInt64 = 3, settledAt: TimeInterval = 0.95,
                     crop: CGFloat = 2, now: TimeInterval = 1.1) -> Bool {
            CameraPreviewCapturePolicy.permits(frame: candidate, generation: generation,
                focalSequence: sequence, sourceRevision: revision, settledAt: settledAt,
                expectedCrop: crop, now: now)
        }
        XCTAssertFalse(permits(captured), "GPU completion alone does not mean the user saw this frame")
        captured.presentedAt = 1.02
        XCTAssertTrue(permits(captured))
        XCTAssertFalse(permits(captured, generation: 2))
        XCTAssertFalse(permits(captured, sequence: 8), "An old 35mm frame cannot authorize a 100mm photo")
        XCTAssertFalse(permits(captured, revision: 4), "A lens change invalidates the old framing immediately")
        XCTAssertFalse(permits(captured, settledAt: 1.01), "Frames captured during the ramp are ineligible")
        XCTAssertFalse(permits(captured, crop: 1), "The proxy crop must have caught up with the source")
        XCTAssertFalse(permits(captured, now: 1.26), "A stalled frame cannot stand in for a live viewfinder")
        captured.presentedAt = 1.2
        XCTAssertFalse(permits(captured), "Future presentation callbacks cannot authorize capture")
    }

    private func frame(rotation: UInt32, crop: CGFloat, outputSize: CGSize) throws -> CameraPreviewFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<4 {
            for x in 0..<8 {
                let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                address[offset] = 0
                address[offset + 1] = (2..<6).contains(x) ? 255 : 0
                address[offset + 2] = (2..<6).contains(x) ? 0 : 255
                address[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return CameraPreviewFrame(buffer: pixels, generation: 1, frameID: 1, capturedAt: 1,
            lutKey: "test", rotation: rotation, crop: crop, outputSize: outputSize, grainSeed: 1)
    }
}
