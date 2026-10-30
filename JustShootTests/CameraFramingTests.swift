import CoreGraphics
import XCTest
@testable import JustShoot

final class CameraFramingTests: XCTestCase {
    func testMetalSamplingAndCapturedPreviewUseTheSameVisibleRect() {
        let input = CGSize(width: 1760, height: 1320)
        let output = CGSize(width: 960, height: 1280)
        for rotation: UInt32 in 0...3 {
            let rotated = rotation == 1 || rotation == 3 ? CGSize(width: input.height, height: input.width) : input
            for zoom: CGFloat in [1, 1.5, 2] {
                let transform = CameraFraming.previewTransform(input: input, rotation: rotation, output: output, zoom: zoom)
                let visible = CGRect(x: -transform.offset.x / transform.scale, y: -transform.offset.y / transform.scale,
                    width: output.width / transform.scale, height: output.height / transform.scale)
                let captured = CameraFraming.centeredCrop(in: CGRect(origin: .zero, size: rotated),
                    aspect: output.width / output.height, zoom: zoom)
                XCTAssertEqual(visible.minX, captured.minX, accuracy: 0.00001)
                XCTAssertEqual(visible.minY, captured.minY, accuracy: 0.00001)
                XCTAssertEqual(visible.width, captured.width, accuracy: 0.00001)
                XCTAssertEqual(visible.height, captured.height, accuracy: 0.00001)
            }
        }
    }

    func testNativePhotoKeepsAllFourEdgesAtEveryResolutionAndOrientation() {
        for size in [CGSize(width: 4032, height: 3024), CGSize(width: 5712, height: 4284),
                     CGSize(width: 3024, height: 4032), CGSize(width: 4284, height: 5712)] {
            let extent = CGRect(origin: CGPoint(x: 13, y: 29), size: size)
            XCTAssertEqual(CameraFraming.photoCrop(in: extent), extent)
        }
    }

    func testUnexpectedAspectIsCroppedIdenticallyWithoutTheOldOnePercentThreshold() {
        let extent = CGRect(x: 20, y: 40, width: 3010, height: 4000)
        let photo = CameraFraming.photoCrop(in: extent)
        let preview = CameraFraming.centeredCrop(in: extent, aspect: CameraFraming.portraitAspect)
        XCTAssertEqual(photo, preview)
        XCTAssertEqual(photo, CGRect(x: 25, y: 40, width: 3000, height: 4000))
    }

    func testProxyCompensationDoesNotCropTheAlreadyZoomedPhotographAgain() {
        // A clamped proxy needs 2x compensation at 200mm. The photo output has
        // already applied the device's 200mm zoom and must retain its full frame.
        let extent = CGRect(x: 0, y: 0, width: 3000, height: 4000)
        let proxy = CameraFraming.centeredCrop(in: extent, aspect: CameraFraming.portraitAspect, zoom: 2)
        XCTAssertEqual(proxy, CGRect(x: 750, y: 1000, width: 1500, height: 2000))
        XCTAssertEqual(CameraFraming.photoCrop(in: extent), extent)
    }
}
