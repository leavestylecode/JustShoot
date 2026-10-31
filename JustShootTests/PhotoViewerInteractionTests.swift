import XCTest
import UIKit
@testable import JustShoot

@MainActor
final class PhotoViewerInteractionTests: XCTestCase {
    func testRotationPreservesZoomAndTheVisibleImageCenter() {
        let image = UIView()
        let viewer = ZoomingScrollView(contentView: image, naturalSize: CGSize(width: 1200, height: 900),
            dismiss: DragDismissController())
        viewer.frame = CGRect(x: 0, y: 0, width: 834, height: 1194)
        viewer.layoutIfNeeded()
        viewer.setZoomScale(2, animated: false)
        viewer.layoutIfNeeded()
        viewer.contentOffset = CGPoint(x: viewer.contentSize.width * 0.6 - viewer.bounds.width / 2,
            y: viewer.contentSize.height * 0.5 - viewer.bounds.height / 2)
        func center() -> CGPoint {
            let point = viewer.convert(CGPoint(x: viewer.bounds.midX, y: viewer.bounds.midY), to: image)
            return CGPoint(x: point.x / image.bounds.width, y: point.y / image.bounds.height)
        }
        let anchor = center()
        for size in [CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194)] {
            viewer.frame.size = size
            viewer.layoutIfNeeded()
            XCTAssertEqual(viewer.zoomScale, 2, accuracy: 0.001)
            XCTAssertEqual(image.bounds.width / image.bounds.height, 4.0 / 3.0, accuracy: 0.001)
            XCTAssertEqual(image.frame.width, viewer.contentSize.width, accuracy: 0.5)
            XCTAssertEqual(image.frame.height, viewer.contentSize.height, accuracy: 0.5)
            XCTAssertEqual(center().x, anchor.x, accuracy: 0.002)
            XCTAssertEqual(center().y, anchor.y, accuracy: 0.002)
        }
    }

    func testFittedPhotoAndChangedAspectStillUseTheWholeViewportAfterRotation() {
        let image = UIView()
        let viewer = ZoomingScrollView(contentView: image, naturalSize: CGSize(width: 1200, height: 900),
            dismiss: DragDismissController())
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834)] {
            viewer.frame.size = size
            viewer.layoutIfNeeded()
            XCTAssertEqual(viewer.zoomScale, 1, accuracy: 0.001)
            XCTAssertLessThanOrEqual(image.frame.width, size.width + 0.5)
            XCTAssertLessThanOrEqual(image.frame.height, size.height + 0.5)
            XCTAssertTrue(abs(image.frame.width - size.width) < 0.5 || abs(image.frame.height - size.height) < 0.5)
        }
        viewer.setZoomScale(3, animated: false)
        viewer.updateNaturalSize(CGSize(width: 900, height: 1200))
        viewer.layoutIfNeeded()
        XCTAssertEqual(viewer.zoomScale, 1, accuracy: 0.001)
        XCTAssertEqual(image.bounds.width / image.bounds.height, 3.0 / 4.0, accuracy: 0.001)
        XCTAssertEqual(image.frame.height, viewer.bounds.height, accuracy: 0.5)
    }

    func testCancelledDismissPreservesImmersiveMode() {
        let controller = DragDismissController()
        controller.toggleChrome()
        controller.begin()
        controller.update(80)
        controller.end(translation: 80, velocity: 0)
        XCTAssertFalse(controller.dragging)
        XCTAssertEqual(controller.translation, 0)
        XCTAssertTrue(controller.chromeHidden)
        controller.toggleChrome()
        XCTAssertFalse(controller.chromeHidden)
    }

    func testImmersiveModeDoesNotPreventDragDismiss() {
        let controller = DragDismissController()
        var dismissed = false
        controller.onDismiss = { dismissed = true }
        controller.toggleChrome()
        controller.begin()
        controller.end(translation: 160, velocity: 0)
        XCTAssertTrue(dismissed)
    }
}
