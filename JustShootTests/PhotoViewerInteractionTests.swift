import XCTest
@testable import JustShoot

@MainActor
final class PhotoViewerInteractionTests: XCTestCase {
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
