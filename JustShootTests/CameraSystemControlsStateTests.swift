import XCTest
@testable import JustShoot

final class CameraSystemControlsStateTests: XCTestCase {
    func testEntryRequirementUpdatesDoNotRepeatNativeControlWrites() {
        var state = CameraSystemControlsState()
        XCTAssertTrue(state.updateEnabled(false))
        for _ in 0..<10 { XCTAssertFalse(state.updateEnabled(false)) }
        XCTAssertTrue(state.updateEnabled(true))
        XCTAssertFalse(state.updateEnabled(true))
        XCTAssertTrue(state.updateEnabled(false))
    }

    func testInvalidationClosesCallbacksWithoutAnotherNativeWrite() {
        for enabled in [false, true] {
            var state = CameraSystemControlsState()
            XCTAssertTrue(state.updateEnabled(enabled))
            state.invalidate()
            XCTAssertFalse(state.isActive)
            XCTAssertFalse(state.updateEnabled(false))
            XCTAssertFalse(state.updateEnabled(true))
        }
    }
}
