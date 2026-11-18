import CoreGraphics
import XCTest
@testable import JustShoot

final class AvatarCropSelectionTests: XCTestCase {
    func testCropSelectionRespondsToZoomAndPanWithinImageBounds() {
        let centered = AvatarCropSelection(viewportSide: 300, zoom: 1, offsetX: 0, offsetY: 0)
        XCTAssertEqual(centered.pixelRect(imageWidth: 1200, imageHeight: 800),
                       CGRect(x: 200, y: 0, width: 800, height: 800))

        let moved = AvatarCropSelection(viewportSide: 300, zoom: 2, offsetX: 150, offsetY: 0)
        XCTAssertEqual(moved.pixelRect(imageWidth: 1200, imageHeight: 800),
                       CGRect(x: 200, y: 200, width: 400, height: 400))

        let clamped = AvatarCropSelection(viewportSide: 300, zoom: 2, offsetX: 1_000, offsetY: 0)
        XCTAssertEqual(clamped.pixelRect(imageWidth: 1200, imageHeight: 800),
                       CGRect(x: 0, y: 200, width: 400, height: 400))
    }
}
